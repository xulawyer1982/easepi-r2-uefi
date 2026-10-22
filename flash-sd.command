#!/bin/bash
# =============================================================================
#  把 EasePi R2 的 EDK2 UEFI 固件写进 SD 卡
#
#  双击运行即可。会：找外接可移除盘 → 让你确认 → 卸载 → dd → 回读校验 → 弹出
#  日志：/tmp/easepi-uefi-flash.log
#
#  写入方式：只写固件本体到 0x8000（跳过镜像自带的 GPT），卡上 32 KiB 之后的
#  区域会被固件覆盖，之后你还能在 UEFI 里重新分区、放系统镜像。
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")" || exit 1

IMG="out/rk3588-easepi-r2-uefi-Release.img"
LOG=/tmp/easepi-uefi-flash.log
EXPECT_SHA="dd53e16153449dc31f2d96221402435c142ed110af0b599cd4e1a40d03068cf8"
SKIP_BLOCKS=64          # 跳过镜像头的 GPT
SEEK_BLOCKS=64          # 写到 0x8000，BootROM 在这里找 idblock
BS=512

exec > >(tee -a "$LOG") 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="

if [ ! -f "$IMG" ]; then
  echo "✘ 找不到固件：$IMG"
  echo "  请确认 out/ 目录里是刚构建出来的 RK3588_NOR_FLASH.img 改名后的文件。"
  read -r -p "按回车退出..." _; exit 1
fi

echo "固件：$IMG"
ls -lh "$IMG" | awk '{print "      "$5}'

# ---- 本地先验一次，镜像本身坏了就别往卡上写 ----
GOT_SHA=$(shasum -a 256 "$IMG" | awk '{print $1}')
echo "sha256：$GOT_SHA"
if [ "$GOT_SHA" != "$EXPECT_SHA" ]; then
  echo "⚠ 本地固件 sha256 与构建记录不一致（可能被改动过）"
  read -r -p "仍要继续？输入 yes 继续：" ans
  [ "$ans" = "yes" ] || { echo "已取消"; exit 1; }
fi

# ---- 找候选盘 ----
echo
echo "=== 可移除磁盘 ==="
CANDIDATES=()
while IFS= read -r line; do
  # 形如：/dev/disk4	外置, 可移动, 磁盘
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

if [ ! -b "$TARGET" ]; then
  echo "✘ $TARGET 不是块设备"; read -r -p "按回车退出..." _; exit 1
fi

echo
echo "===== 即将写入：$TARGET ====="
diskutil info "$TARGET" | grep -E "Device / Media Name|Disk Size|Removable Media|Protocol|Volume Name" | sed 's/^/   /'
echo
echo "⚠ 这会覆盖该盘 32 KiB 之后的全部内容（含原有分区表数据区）。"
read -r -p "确认写入？输入大写 YES 继续：" ans
[ "$ans" = "YES" ] || { echo "已取消，什么都没动。"; read -r -p "按回车退出..." _; exit 0; }

RDISK=$(echo "$TARGET" | sed 's|/dev/|/dev/r|')
echo
echo "▸ 卸载 $TARGET ..."
diskutil unmountDisk force "$TARGET" || true

echo "▸ 写入 $IMG → $RDISK (offset $((SEEK_BLOCKS*BS)) = 0x$(printf '%x' $((SEEK_BLOCKS*BS)))) ..."
if ! sudo dd if="$IMG" of="$RDISK" bs=${BS} skip=${SKIP_BLOCKS} seek=${SEEK_BLOCKS} conv=notrunc 2>&1 | tail -5; then
  echo "✘ 写入失败。若是 'Operation not permitted'，说明终端没有「完全磁盘访问权限」："
  echo "   系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 勾选你要用的终端 App，然后重开终端再跑。"
  read -r -p "按回车退出..." _; exit 1
fi
sync

# ---- 回读校验：从 0x8000 起读同样长度，与镜像 skip 掉 GPT 的部分比对 ----
TOTAL_BLOCKS=$(( $(stat -f%z "$IMG") / BS ))
READ_BLOCKS=$(( TOTAL_BLOCKS - SKIP_BLOCKS ))
echo
echo "▸ 回读校验（$READ_BLOCKS 块）..."
WANT=$(dd if="$IMG" bs=${BS} skip=${SKIP_BLOCKS} count=${READ_BLOCKS} 2>/dev/null | shasum -a 256 | awk '{print $1}')
GOT=$(sudo dd if="$RDISK" bs=${BS} skip=${SEEK_BLOCKS} count=${READ_BLOCKS} 2>/dev/null | shasum -a 256 | awk '{print $1}')
echo "   期望：$WANT"
echo "   实测：$GOT"
if [ "$WANT" = "$GOT" ]; then
  echo "✔ 校验一致"
else
  echo "✘ 校验不一致！重写一次看看，或者换张卡。"
fi

echo
echo "▸ 弹出 $TARGET ..."
diskutil eject "$TARGET" || true

echo
echo "===== 完成 ====="
echo "把卡插到 EasePi R2，串口接 ttyS2（1500000 8N1）看启动日志。"
echo "固件在 0x8000 处应是 RKNS 魔数，UEFI 从 1 MiB 处的 FIT 起来。"
read -r -p "按回车关闭..." _
