#!/bin/bash
# =============================================================================
#  把完整刷机盘写进 SD 卡（UEFI 固件 + GRUB + 网页刷机 recovery）
#
#  双击运行。会：找外接可移除盘 → 显示盘信息 → 要你确认 → 卸载 → 整盘 dd
#                → 回读校验 → 弹出
#
#  日志：/tmp/easepi-full-sd.log
#
#  注意：这是【整盘写入】，卡上原有内容全部作废。
#        与只写固件到 0x8000 的 flash-sd.command 不同，不要混用。
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1

IMG="out/fxrecovery-easepi-r2-sd.img"
LOG=/tmp/easepi-full-sd.log
SUMS="out/SD_SHA256SUMS"

exec > >(tee -a "$LOG") 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="

[ -f "$IMG" ] || {
  echo "✘ 找不到镜像：$IMG"
  echo "  先跑 scripts/build-sd.sh（本地）或从 GitHub Actions 下载产物。"
  read -r -p "按回车退出..." _; exit 1
}

IMG_BYTES=$(stat -f%z "$IMG" 2>/dev/null || stat -c%s "$IMG")
echo "镜像：$IMG"
echo "大小：$(( IMG_BYTES / 1048576 )) MiB"
echo "sha256：$(shasum -a 256 "$IMG" | awk '{print $1}')"
[ -f "$SUMS" ] && echo "记录值：$(awk '{print $1}' "$SUMS")"

echo
echo "=== 可移除磁盘 ==="
CANDIDATES=()
while IFS= read -r line; do
  dev=$(echo "$line" | awk '{print $1}')
  info=$(echo "$line" | sed "s|^$dev[[:space:]]*||")
  case "$info" in
    *可移动*|*removable*|*外置*|*external*)
      CANDIDATES+=("$dev")
      echo "  $dev  —  $info"
      ;;
  esac
done < <(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk/ {print $1"\t"$0}' | cut -f2-)

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  echo "✘ 没有检测到外接可移除盘。插好读卡器再运行。"
  read -r -p "按回车退出..." _; exit 1
fi

if [ ${#CANDIDATES[@]} -eq 1 ]; then
  TARGET="${CANDIDATES[0]}"
else
  echo
  read -r -p "输入目标盘（例如 disk4）：" pick
  TARGET="/dev/${pick#/dev/}"
fi

[ -b "$TARGET" ] || { echo "✘ $TARGET 不是块设备"; read -r -p "按回车退出..." _; exit 1; }

# 容量必须够
DISK_BYTES=$(diskutil info -plist "$TARGET" 2>/dev/null | \
  /usr/libexec/PlistBuddy -c "Print :Size" /dev/stdin 2>/dev/null || echo 0)
if [ "${DISK_BYTES:-0}" -gt 0 ] && [ "$DISK_BYTES" -lt "$IMG_BYTES" ]; then
  echo "✘ 卡容量不足：卡 $(( DISK_BYTES / 1048576 )) MiB < 镜像 $(( IMG_BYTES / 1048576 )) MiB"
  read -r -p "按回车退出..." _; exit 1
fi

echo
echo "===== 即将整盘写入：$TARGET ====="
diskutil info "$TARGET" | grep -E "Device / Media Name|Disk Size|Removable Media|Protocol|Volume Name" | sed 's/^/   /'
echo
echo "⚠ 整盘覆盖：该盘现有全部分区与数据立即作废，不可恢复。"
read -r -p "确认写入？输入大写 YES 继续：" ans
[ "$ans" = "YES" ] || { echo "已取消，什么都没动。"; read -r -p "按回车退出..." _; exit 0; }

RDISK=$(echo "$TARGET" | sed 's|/dev/|/dev/r|')
echo
echo "▸ 卸载 $TARGET ..."
diskutil unmountDisk force "$TARGET" || true

echo "▸ 写入 $IMG → $RDISK ..."
if ! sudo dd if="$IMG" of="$RDISK" bs=1m 2>&1 | tail -3; then
  echo "✘ 写入失败。若是 'Operation not permitted'，说明当前终端没有「完全磁盘访问权限」："
  echo "   系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 勾选你用的终端 App，重开终端再跑。"
  read -r -p "按回车退出..." _; exit 1
fi
sync

# 回读头部 8 MiB 校验引导区（整盘读太慢，头部足以确认写对了）
READ_MIB=8
echo
echo "▸ 回读校验（前 ${READ_MIB} MiB 引导区）..."
WANT=$(dd if="$IMG" bs=1m count=$READ_MIB 2>/dev/null | shasum -a 256 | awk '{print $1}')
GOT=$(sudo dd if="$RDISK" bs=1m count=$READ_MIB 2>/dev/null | shasum -a 256 | awk '{print $1}')
echo "   期望：$WANT"
echo "   实测：$GOT"
if [ "$WANT" = "$GOT" ]; then
  echo "✔ 引导区一致（含 idblock 与 UEFI 固件）"
else
  echo "✘ 不一致！重写一次，或换张卡。"
fi

echo
echo "▸ 弹出 $TARGET ..."
diskutil eject "$TARGET" || true

echo
echo "===== 完成 ====="
echo "插到 EasePi R2，接串口 ttyS2 @ 1500000 8N1 看启动日志。"
echo "正常流程：UEFI → GRUB 菜单 → 选 fxrecovery → 屏幕/串口会打印网页地址。"
read -r -p "按回车关闭..." _
