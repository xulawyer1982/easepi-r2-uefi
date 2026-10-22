#!/bin/bash
# =============================================================================
#  组装 EasePi R2 的完整刷机 SD 卡镜像
#
#  产物 = UEFI 固件 + FAT16 ESP（96 MiB，≥256 MiB 才用 FAT32）（GRUB + Linux recovery + 网页刷机程序）
#
#  最终启动链：
#    BootROM → idblock(SPL+ATF) → EDK2 UEFI → GRUB → Linux → 网页刷机 → dd 写盘
#
#  用法：
#    ./build-sd.sh                       # 用默认路径找资产
#    ./build-sd.sh --esp-size 128        # 指定 ESP 大小（MiB）
#    ./build-sd.sh --assets DIR --grub PATH --fxrecovery PATH
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."          # 脚本在 scripts/ 下，仓库根是上一级
ROOT="$(pwd)"

FW_IMG="${ROOT}/out/rk3588-easepi-r2-uefi-Release.img"
ESP_SIZE=96
ASSETS="${ROOT}/../fx-recovery/assets"
FXAPP="${ROOT}/../fx-recovery/out/fxrecovery"
GRUB_EFI=""
OUT="${ROOT}/out"
DTB="${ROOT}/devicetree/vendor/rk3588-easepi-r2.dtb"
KVER=6.18.18-trim

while [ $# -gt 0 ]; do
  case "$1" in
    --esp-size)   ESP_SIZE="$2"; shift 2 ;;
    --assets)     ASSETS="$2"; shift 2 ;;
    --fxrecovery) FXAPP="$2"; shift 2 ;;
    --grub)       GRUB_EFI="$2"; shift 2 ;;
    --fw)         FW_IMG="$2"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

info() { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 检查 --
info "⓪ 检查依赖"
[ -f "${FW_IMG}" ]  || die "缺 UEFI 固件：${FW_IMG}（先跑 CI 或本地编译）"
[ -f "${DTB}" ]     || die "缺设备树：${DTB}"
[ -f "${ASSETS}/Image" ] || die "缺内核：${ASSETS}/Image"
[ -f "${ASSETS}/busybox" ] || die "缺 busybox：${ASSETS}/busybox"
[ -f "${FXAPP}" ]   || die "缺网页刷机程序：${FXAPP}"

if [ -z "${GRUB_EFI}" ]; then
  for c in \
    "/tmp/grubdeb/x/usr/lib/grub/arm64-efi/monolithic/grubaa64.efi" \
    "/usr/lib/grub/arm64-efi/monolithic/grubaa64.efi" \
    "${ROOT}/assets/grubaa64.efi"; do
    [ -f "${c}" ] && { GRUB_EFI="${c}"; break; }
  done
fi
[ -n "${GRUB_EFI}" ] && [ -f "${GRUB_EFI}" ] || \
  die "缺 GRUB arm64 EFI，请用 --grub 指定，或跑 scripts/fetch-grub.sh"

ok "固件 $(du -h "${FW_IMG}" | cut -f1) / 内核 $(du -h "${ASSETS}/Image" | cut -f1)"
ok "GRUB $(du -h "${GRUB_EFI}" | cut -f1) → ${GRUB_EFI}"

WORK="${OUT}/sdwork"
rm -rf "${WORK}"; mkdir -p "${WORK}"

# ------------------------------------------------------------ 1. initramfs --
info "① 组装 initramfs"
R="${WORK}/rootfs"
mkdir -p "${R}"/{bin,sbin,etc,proc,sys,dev,dev/pts,tmp,run,images,mnt,media/probe,lib/modules,lib/firmware,usr/bin,usr/sbin,efi}

install -m755 "${ASSETS}/busybox" "${R}/bin/busybox"
for a in sh ash mount umount mkdir ls cat dd sync sleep modprobe ip udhcpc \
         mdev awk grep sed cut head tail tr wc ln rm cp mv chmod mountpoint \
         dmesg blkid find switch_root clear less vi reboot poweroff basename; do
  ln -sf busybox "${R}/bin/${a}"
done

install -m755 "${FXAPP}"            "${R}/fxrecovery"
install -m755 "${ROOT}/recovery/init"        "${R}/init"
install -m755 "${ROOT}/recovery/udhcpc.sh"   "${R}/etc/udhcpc.sh"

# 内核模块：只挑网卡相关
MODROOT="${ASSETS}/modules"
if [ -d "${MODROOT}/${KVER}" ]; then
  mkdir -p "${R}/lib/modules/${KVER}"
  cp -a "${MODROOT}/${KVER}"/modules.* "${R}/lib/modules/${KVER}/" 2>/dev/null || true
  while IFS= read -r ko; do
    [ -n "${ko}" ] || continue
    rel="${ko#${MODROOT}/${KVER}/}"
    mkdir -p "${R}/lib/modules/${KVER}/$(dirname "${rel}")"
    cp "${ko}" "${R}/lib/modules/${KVER}/${rel}"
  done < <(find "${MODROOT}/${KVER}" -name "*.ko" 2>/dev/null | grep -E "r8169|stmmac|dwmac|pcs_xpcs" || true)
  ok "内核模块 $(find "${R}/lib/modules/${KVER}" -name '*.ko' | wc -l | tr -d ' ') 个"
fi

[ -d "${ASSETS}/firmware" ] && cp -a "${ASSETS}/firmware/." "${R}/lib/firmware/" 2>/dev/null || true

INITRAMFS="${WORK}/initramfs.cpio.gz"
( cd "${R}" && find . -print | cpio -o -H newc 2>/dev/null | gzip -9 ) > "${INITRAMFS}"
ok "initramfs $(du -h "${INITRAMFS}" | cut -f1)"

# ------------------------------------------------------------- 2. 容量预检 --
info "② 容量预检"
NEED=0
for f in "${ASSETS}/Image" "${INITRAMFS}" "${DTB}" "${GRUB_EFI}" "${FXAPP}"; do
  NEED=$(( NEED + $(wc -c < "${f}") ))
done
NEED_MIB=$(( (NEED + NEED / 20 + 1048576) / 1048576 + 4 ))   # +5% 余量 + 目录开销
if [ "${ESP_SIZE}" -lt "${NEED_MIB}" ]; then
  die "ESP 太小：内容需要 ${NEED_MIB} MiB，当前 ${ESP_SIZE} MiB。请用 --esp-size $(( NEED_MIB + 8 ))"
fi
ok "内容 ${NEED_MIB} MiB / ESP ${ESP_SIZE} MiB"

# ---------------------------------------------------------------- 3. ESP --
info "③ 制作 ESP 分区"
PART_START_SECTOR=18432        # 9 MiB，给 8 MiB 的固件区留余量
PART_SECTORS=$(( ESP_SIZE * 2048 ))
FATIMG="${WORK}/esp.fat"
FATDMG="${WORK}/esp.fat.dmg"
MNT="${WORK}/espmnt"
mkdir -p "${MNT}"

if [ "$(uname -s)" = "Darwin" ]; then
  hdiutil detach "${MNT}" -force >/dev/null 2>&1 || true
  hdiutil create -size "${ESP_SIZE}m" -fs MS-DOS -volname FXBOOT -layout NONE -ov "${FATDMG}" >/dev/null
  hdiutil attach -nobrowse -mountpoint "${MNT}" "${FATDMG}" >/dev/null
  DEST="${MNT}"
else
  dd if=/dev/zero of="${FATIMG}" bs=1M count="${ESP_SIZE}" status=none
  if [ "${ESP_SIZE}" -ge 256 ]; then MKFAT="-F 32"; else MKFAT="-F 16"; fi
  mkfs.vfat ${MKFAT} -n FXBOOT "${FATIMG}" >/dev/null
  MTOOLS="-i ${FATIMG}"
  DEST=""
fi

# 组织文件树
T="${WORK}/esp"
rm -rf "${T}"; mkdir -p "${T}"/{EFI/BOOT,boot/dtb,boot/grub,images}
cp "${GRUB_EFI}"            "${T}/EFI/BOOT/BOOTAA64.EFI"
cp "${ROOT}/recovery/grub.cfg" "${T}/EFI/BOOT/grub.cfg"
cp "${ROOT}/recovery/grub.cfg" "${T}/boot/grub/grub.cfg"
cp "${ASSETS}/Image"        "${T}/boot/Image"
cp "${INITRAMFS}"           "${T}/boot/initramfs.cpio.gz"
cp "${DTB}"                 "${T}/boot/dtb/rk3588-easepi-r2.dtb"
cp "${FXAPP}"               "${T}/fxrecovery"
printf 'EasePi R2 fxrecovery - 请勿删除本文件，init 依赖它定位启动分区\n' > "${T}/fx-recovery.tag"

if [ "$(uname -s)" = "Darwin" ]; then
  cp -a "${T}/." "${MNT}/"
  # macOS 往 FAT 上写 AppleDouble 元数据（._xxx）和 .fseventsd。
  # 这些不是给固件看的，必须清掉：既白占空间，也可能干扰 UEFI 的目录扫描。
  rm -rf "${MNT}/.fseventsd" "${MNT}/.Trashes" "${MNT}/.Spotlight-V100" 2>/dev/null || true
  find "${MNT}" -name '._*' -type f -delete 2>/dev/null || true
  find "${MNT}" -name '.DS_Store' -type f -delete 2>/dev/null || true
  sync
  echo "  写入 $(find "${MNT}" -type f | wc -l | tr -d ' ') 个文件（已清 macOS 元数据）"
  hdiutil detach "${MNT}" >/dev/null 2>&1 || hdiutil detach "${MNT}" -force >/dev/null
  # hdiutil 产出的是纯 FAT 镜像（无分区表），取出来直接当分区内容用
  cp "${FATDMG}" "${FATIMG}"
  # detach 时系统又会重建 .Trashes/.fseventsd，此时已经无法再靠 rm 解决，
  # 直接在 FAT16 根目录层面把这两个目录项标记为已删除（首字节 0xE5）。
  python3 - "${FATIMG}" <<'PY'
import sys, struct
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
bps   = struct.unpack('<H', d[11:13])[0]
resv  = struct.unpack('<H', d[14:16])[0]
nfat  = d[16]
rootn = struct.unpack('<H', d[17:19])[0]
fatsz = struct.unpack('<H', d[22:24])[0]
root_off = (resv + nfat * fatsz) * bps
root_len = rootn * 32
# FAT 8.3 短名会把 ".Trashes" 存成 "TRASHES~1"/"TRASH~15" 这类别名，
# 所以只能按前缀匹配，不能用全名。
bad = (b'TRASH', b'FSEVENT', b'SPOTLIG', b'DS_STORE', b'DSSTORE')
n = 0
lfn_start = None
for off in range(root_off, min(root_off + root_len, len(d) - 32), 32):
    first = d[off]
    if first == 0x00:
        break
    attr = d[off + 11]
    if attr == 0x0F:                       # LFN 项，记下起点
        if lfn_start is None:
            lfn_start = off
        continue
    short = bytes(d[off:off + 11]).upper()
    hit = any(short.startswith(k) for k in bad) or first == 0x2E
    if hit:
        if lfn_start is not None:          # 连同 LFN 链一起删
            for o in range(lfn_start, off, 32):
                d[o] = 0xE5
        d[off] = 0xE5
        n += 1
    lfn_start = None
open(p, 'wb').write(d)
print("  清掉 macOS 残留目录项 %d 个" % n)
PY
else
  # mtools 的 mcopy 不会自动创建目标父目录，必须先 mmd，否则报
  #   "::/EFI/BOOT/grub.cfg: no match for target"
  for d in EFI EFI/BOOT boot boot/dtb boot/grub images; do
    mmd ${MTOOLS} "::/${d}" 2>/dev/null || true
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mcopy ${MTOOLS} -o -s "${T}/${f}" "::/${f}"
  done < <(cd "${T}" && find . -type f | sed 's|^\./||')
  echo "  写入 $(cd "${T}" && find . -type f | wc -l | tr -d ' ') 个文件"
fi

ok "ESP 就绪"

# ------------------------------------------------------ 4. 拼整盘镜像 + MBR --
info "④ 拼装整盘镜像"
TOTAL_SECTORS=$(( PART_START_SECTOR + PART_SECTORS ))
TOTAL_BYTES=$(( TOTAL_SECTORS * 512 ))
SD_IMG="${OUT}/fxrecovery-easepi-r2-sd.img"
rm -f "${SD_IMG}"

python3 - "${SD_IMG}" "${TOTAL_BYTES}" <<'PY'
import sys
path, size = sys.argv[1], int(sys.argv[2])
with open(path, 'wb') as f:
    f.truncate(size)          # 稀疏文件，不实际写零
PY
ok "空镜像 $(( TOTAL_BYTES / 1048576 )) MiB"

# 4a. UEFI 固件 → 0x8000
FW_SIZE=$(wc -c < "${FW_IMG}")
FW_BODY=$(( FW_SIZE - 32768 ))     # 镜像前 32 KiB 是 NOR 用的 GPT，SD 卡不要
SKIP64=$(( FW_BODY % 512 ))
[ "${SKIP64}" -ne 0 ] && FW_BODY=$(( FW_BODY - SKIP64 ))
dd if="${FW_IMG}" of="${SD_IMG}" bs=512 skip=64 count=$(( FW_BODY / 512 )) \
   seek=64 conv=notrunc status=none 2>/dev/null || \
dd if="${FW_IMG}" of="${SD_IMG}" bs=512 skip=64 seek=64 conv=notrunc
ok "固件 $(($(wc -c < "${FW_IMG}") / 1024)) KiB → 0x8000"
[ "$(( 32768 + FW_BODY ))" -le "$(( PART_START_SECTOR * 512 ))" ] || \
  die "固件与分区重叠：固件到 $(( 32768 + FW_BODY ))，分区从 $(( PART_START_SECTOR * 512 ))"

# 4b. ESP 内容 → 分区起点
dd if="${FATIMG}" of="${SD_IMG}" bs=512 seek=${PART_START_SECTOR} \
   count=${PART_SECTORS} conv=notrunc status=none 2>/dev/null || \
dd if="${FATIMG}" of="${SD_IMG}" bs=512 seek=${PART_START_SECTOR} conv=notrunc
ok "ESP $(( ESP_SIZE )) MiB → sector ${PART_START_SECTOR}"

# 4c. MBR
python3 - "${SD_IMG}" "${PART_START_SECTOR}" "${PART_SECTORS}" <<'PY'
import sys, struct
img, start, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(img, 'r+b') as f:
    f.seek(0)
    mbr = bytearray(512)
    # 分区项 0
    e = bytearray(16)
    e[0] = 0x00                       # 非活动
    e[1:4] = b'\xfe\xff\xff'          # CHS 起始（LBA 模式忽略）
    e[4] = 0x0c                       # FAT32 LBA
    e[5:8] = b'\xfe\xff\xff'          # CHS 结束
    struct.pack_into('<I', e, 8, start)
    struct.pack_into('<I', e, 12, count)
    mbr[446:462] = e
    mbr[510:512] = b'\x55\xAA'
    f.write(bytes(mbr))
print("  MBR: type=0x0c start=%d count=%d (%d MiB)" % (start, count, count*512//1048576))
PY

sync
ok "镜像完成"

# ------------------------------------------------------------- 5. 自检 --
info "⑤ 结构自检"
python3 - "${SD_IMG}" <<'PY'
import sys, struct
p = sys.argv[1]
d = open(p, 'rb').read()
print("  镜像大小   : %d bytes (%.1f MiB)" % (len(d), len(d)/1048576))
ok = True
# idblock
sig = d[0x8000:0x8004]
print("  idblock    : %s  %s" % (sig, "RKNS ✔" if sig == b'RKNS' else "BAD ✘"))
ok &= sig == b'RKNS'
# FIT
fit = d[0x100000:0x100004]
tot = struct.unpack('>I', d[0x100004:0x100008])[0]
print("  FIT @1MiB  : %s totalsize=%d  %s" % (fit.hex(), tot, "OK ✔" if fit == b'\xd0\x0d\xfe\xed' else "BAD ✘"))
ok &= fit == b'\xd0\x0d\xfe\xed'
# MBR
mbr = d[0:512]
print("  MBR 签名   : %s  %s" % (mbr[510:512].hex(), "OK ✔" if mbr[510:512] == b'\x55\xaa' else "BAD ✘"))
ok &= mbr[510:512] == b'\x55\xaa'
ps = struct.unpack('<I', mbr[454:458])[0]
pc = struct.unpack('<I', mbr[458:462])[0]
pt = mbr[450]
print("  分区 1     : type=0x%02x LBA %d ~ %d (%.0f MiB)  %s" %
      (pt, ps, ps+pc, pc*512/1048576, "OK ✔" if pt == 0x0c else "BAD ✘"))
ok &= pt == 0x0c
# 分区内 FAT 引导扇区
fat = d[ps*512 : ps*512+512]
print("  FAT 引导扇 : %s  %s" % (fat[54:62], "FAT32 ✔" if fat[82:87] == b'FAT32' else ("FAT16 ✔" if fat[54:59] in (b'FAT16', b'FAT12') else "?")))
print("  结果       : %s" % ("全部通过 ✔" if ok else "有问题 ✘"))
sys.exit(0 if ok else 1)
PY
SELFOK=$?

if [ "${SELFOK}" -ne 0 ]; then
  die "自检未通过"
fi

# ------------------------------------------------------------- 6. 收尾 --
rm -rf "${WORK}"
ls -lh "${SD_IMG}"
( cd "${OUT}" && shasum -a 256 "$(basename "${SD_IMG}")" 2>/dev/null || sha256sum "$(basename "${SD_IMG}")" ) | tee "${OUT}/SD_SHA256SUMS"

echo
printf '\033[1;32m完成：%s\033[0m\n' "${SD_IMG}"
echo "写卡：  sudo dd if=$(basename "${SD_IMG}") of=/dev/rdiskN bs=1m"
echo "        （整盘写，不要 skip/seek）"
