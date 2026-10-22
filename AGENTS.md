# AGENTS.md — 给 AI 编码智能体的项目说明

> 接手本项目先读这一份，不必再翻 README（那是给人看的）和上游上千行移植笔记。
> 最后核对：2026-10-22。文中所有数字都是在真板子 / 实际产物上量过的，别用"通常值"覆盖。

---

## 1. 这是什么

**LinkEase EasePi R2（RK3588）的 EDK2 UEFI 板级移植 + 自研网页刷机盘**，以 overlay 方式叠加到上游
[edk2-porting/edk2-rk3588](https://github.com/edk2-porting/edk2-rk3588) 上构建。

- 本仓库**不含** UEFI 源码，只有 7 个板级文件（DSC / 模块表 / ACPI / DeviceTree.inf / PlatformLib 2 个）+ 打包脚本 + recovery 程序 + CI。
- 目标硬件：LinkEase EasePi R2（4× RTL8125 2.5G 网口，NVMe 系统盘，eMMC 29 GiB，无 SPI NOR）。
- **本仓库是公开仓库：不要写入任何内网地址、主机名、Tailscale 域名、真实姓名或邮箱。**
  需要举例时用 `192.0.2.x`（RFC 5737 文档专用段）/ `example.local` 这类占位值。
- 边界：**只做固件与引导**。不要往这里塞系统镜像、Docker、NAS 相关逻辑。

启动链（两种产物共用前半段）：

```
BootROM → idblock(SPL+ATF) → EDK2 UEFI → GRUB → Linux(6.18.18-trim) → initramfs
        → Go 网页服务 → 浏览器选盘选镜像 → dd 写 NVMe/SATA
```

---

## 2. 目录约定

| 路径 | 作用 | 改这里会影响 |
|:--|:--|:--|
| `platform/EasePiR2/` | 板级 DSC / 模块表 / DeviceTree.inf / RockchipPlatformLib / ACPI | 最终 overlay 到 `edk2-rockchip/Platform/Radxa/EasePiR2/` |
| `configs/easepi-r2.conf` | 只放 3 行：`DSC_FILE` / `PLATFORM_NAME` / `SOC`。公共的 `MINIALL_INI`、`TRUST_INI`、`TFA_PLAT` 由上游 `configs/RK3588.conf` 提供 | 板卡名、DSC 路径 |
| `devicetree/vendor/rk3588-easepi-r2.dtb` | 厂商设备树（218,053 B），一切板级参数的唯一事实来源 | UEFI 早期初始化 + 传给 OS 的 DTB |
| `recovery/init` `recovery/grub.cfg` `recovery/udhcpc.sh` | 打包进 initramfs 的启动逻辑 | 刷机盘能否找到 ESP、能否起网 |
| `scripts/build-sd.sh` | 组装 105 MiB 刷机盘 | 分区偏移、FAT、文件布局 |
| `scripts/upload-payload.py` | 把 recovery payload（15.7 MiB）传到 GitHub prerelease `payload-k6.18.18-trim` | CI 拉取源 |
| `flash-sd.command` / `flash-recovery-sd.command` | macOS 双击写卡（窄写固件 / 整盘写） | 用户操作入口 |
| `out/` | 构建产物，**不要提交** | — |

---

## 3. 构建

CI（首选，Linux 环境干净）：推 `main` 或手动 `workflow_dispatch`，产物是 artifact。

```bash
# 本地：Linux / WSL / Docker
git clone --depth 1 https://github.com/edk2-porting/edk2-rk3588.git up && cd up
git config submodule."devicetree/mainline/upstream".active false   # kernel.googlesource.com 常 502
git submodule update --init --recursive --depth 1 \
  edk2 edk2-platforms edk2-non-osi arm-trusted-firmware misc/rkbin
cp -a ../platform/EasePiR2/. edk2-rockchip/Platform/Radxa/EasePiR2/
cp ../devicetree/vendor/rk3588-easepi-r2.dtb devicetree/vendor/
cp ../configs/easepi-r2.conf configs/
./build.sh --device easepi-r2 --release Release     # → RK3588_NOR_FLASH.img（约 6.98 MB）
```

- **`--recursive` 不可省**：`brotli/c/common/constants.h` 在二级子模块里，缺了 BaseTools 就编译失败。
- 若 `devicetree/mainline/upstream` 拉不下来：`RockchipPkg.dec` 的 `[Includes]` 里写死了它的
  `include/` 和 `src/arm64/rockchip/` 路径，目录不存在连构建都起不来。CI 的做法是先尝试拉取、失败就
  `mkdir -p` 兜底（我们不编译主线 DTS，只要有目录）；本机可直接 `submodule.<name>.active false`。
- 上游 `build.sh` 自带 `--pcd gRockchipTokenSpaceGuid.PcdFitImageFlashAddress=0x100000`，**别重复传、也别去掉**。
- macOS 上 `scripts/build-sd.sh` 走 `hdiutil` 分支，产物会带 `.Trashes`/`TRASH~15`，**只有 Linux 分支的产物可当交付**。

---

## 4. 产物与固定偏移（改了就砖）

| 产物 | 大小 | sha256 |
|:--|--:|:--|
| `out/rk3588-easepi-r2-uefi-Release.img` | 6,977,536 B | `dd53e16153449dc31f2d96221402435c142ed110af0b599cd4e1a40d03068cf8` |
| `out/fxrecovery-easepi-r2-sd.img` | 110,100,480 B（105 MiB） | `5bb24215291806feb09472be1ea71d2aad7571c03bd398420ce52de4d588a596` |

固件内部偏移（**BootROM 在这里找东西，一个字节都不能挪**）：

| 偏移 | 内容 | 魔数 / 说明 |
|--:|:--|:--|
| `0x00000000` | GPT（仅 SPI NOR 用，SD/eMMC 写入时跳过前 32768 B） | — |
| `0x00008000` | IDBlock = DDR init + SPL + ATF | `RKNS` |
| `0x00100000` | BL33_AP_UEFI FV（UEFI 本体） | `d00dfeed`（FIT） |
| `0x007C0000` | NV 变量存储 / FTW working / spare（各 64 KiB） | — |

刷机盘（105 MiB）布局：

| 位置 | 内容 |
|:--|:--|
| 0 – 8 MiB | 上述固件体（`skip=64` 丢 GPT，`seek=64` 写到 0x8000） |
| LBA 18432（9 MiB）起 | 96 MiB **FAT16**（卷标 `FXBOOT`，`mkfs.vfat -F 16`；≥256 MiB 时才用 FAT32） |
| ESP 内容 | `EFI/BOOT/BOOTAA64.EFI`（GRUB monolithic 4.1 MB）、`EFI/BOOT/grub.cfg`、`boot/grub/grub.cfg`、`boot/Image`、`boot/initramfs.cpio.gz`、`boot/dtb/rk3588-easepi-r2.dtb`、`fxrecovery`（6 MB）、`fx-recovery.tag` |

三处偏移必须同步：`build.sh`/`dd` 的 `seek=1024` ↔ `build-sd.sh` 的 `PART_START_SECTOR=18432` ↔ README 表格。

---

## 5. 板级事实（实测，勿推翻）

- **eMMC**：`DF4032` 29.1 GiB，HS400，`life_time=0x01 0x01`（磨损 0–20%），GPT 仅 1 个 `BOOT` 分区（511 MiB ext4，挂 `/boot`），未分区空间 ≈28.6 GiB。
- **原厂引导链**：U-Boot `2026.04_armbian-2026.04-...`，idbloader @ `32768`，`u-boot.itb` @ `8388608`，引导区 0–16 MiB。
- **无 SPI NOR**（`/proc/mtd` 为空，无 `/dev/mtd*`）。
- **串口是唯一可靠诊断口**：`ttyS2`（`0xfeb50000`）**1500000 8N1**。
- **DTB compatible**：`linkease,easepi-r2`, `easepi,r2`, `rockchip,rk3588`；`/reserved-memory` 含 `shmem@10f000`(no-map) + `hdmi-receiver-cma`（UEFI 不会踩 TF-A 内存）。
- **PCIe 复位脚**（低有效，全部取自 DTB `reset-gpios`）：pcie3x4=GPIO4_PB6(NVMe)、pcie3x2=GPIO0_PC5、pcie2x1l0=GPIO4_PA7、pcie2x1l1=GPIO3_PC7、pcie2x1l2=GPIO3_PC1。
- **NLDO3 = `avdd_0v75_s0` = 837500 µV**（DTB 里 min==max），是厂商固定设定，**不是笔误**。

---

## 6. 硬禁区（违反＝烧板或丢数据）

1. **不写 eMMC 前 16 MiB**，除非用户明确要求清 eMMC。刷 SD 卡绝不碰 eMMC。
2. **不改 `avdd_0v75_s0`**（837 mV 是原厂设定）；不改第三个 RK860（i2c1 `0x42`，作用未知）。
3. **保持这些函数为空**：`PciePowerEn`、`PwmFanIoSetup`、`PlatformSetStatusLed`、`PlatformPcieWiFiEnable` —— R2 的 DTB 里没有对应描述，猜错引脚会把电源轨拉进非法状态。
4. **不照抄 BDY_G98 的 recovery 流程**：G98 只支持 SPI NOR、eMMC 明确禁用、启动序 USB→NVMe→SATA、只扫分区 1/2。R2 没有 SPI NOR，且**必须**靠 eMMC/SD 当引导中间层。
5. **不要假设 BootROM 能从 NVMe/SATA 启动**。SSD 上的系统永远需要 SD 卡（或 eMMC 里的固件）当跳板。
6. 不要为了"省事"把 `CONFIG` 里的 `PcdFitImageFlashAddress` 改成别的值来适配新布局 —— 应改的是 dd 偏移。
7. 不要提交 `out/`、`recovery-payload.tar.gz`（15.7 MiB 二进制）。
8. **提交前自查**（本仓库公开，2026-10-22 曾因缺失这一步泄露过内网地址）：

   ```bash
   git grep -nIE "192\.168\.|10\.[0-9]+\.[0-9]+\.|172\.(1[6-9]|2[0-9]|3[01])\.|@qq\.com|@outlook|/Users/"
   ```

   必须为空。已经 push 出去的：改写历史（`filter-branch --tree-filter` + `--force-with-lease` 强推）
   + 本地 `git reflog expire --expire=now --all && git gc --prune=now`；注意 GitHub 侧旧 commit 对象
   短期仍可用 SHA 直链访问，彻底清除要联系 GitHub Support。

---

## 7. 已知坑（都踩过）

| 症状 | 根因 | 处理 |
|:--|:--|:--|
| ESP 里多出 `TRASH~15` / `._*` / `.fseventsd` | macOS 往 FAT 写元数据，8.3 别名把 `.Trashes` 变成 `TRASH~15` | Linux 构建；或 detach 后在 FAT 根目录按前缀标 `0xE5` |
| `unbound variable` 且指向中文字符 | bash 3.2 把 `$VAR中文` 当成一个变量名 | 一律写 `${VAR}中文` |
| `::/EFI/BOOT/grub.cfg: no match for target` | `mcopy` 不自动建父目录 | 先 `mmd`，再 `mcopy` |
| GRUB 反复 chainload 自己 | `grub.cfg` 里 `"($disk,$part)" != "$root"` 少括号，`$root` 永远为真 | 比较前先展开成带括号的字符串 |
| 验证镜像时凭空多出 `.Trashes` | 可写挂载会让 macOS 自己创建 | `hdiutil attach -readonly`，或直接按字节解 FAT |
| `kernel.googlesource.com` 502 | 本机/CI 到该域必挂 | 关掉该子模块：`submodule."devicetree/mainline/upstream".active false` |
| `github.com:443` 502 | 网络抖动 | push 重试 5–15 次 |
| Actions job 日志 401 | `/actions/jobs/{id}/logs` 302 到 Azure Blob，带 Authorization 会拒绝 | 手动跟 302 并**丢掉** Authorization；返回是**纯文本**不是 zip |
| U-Boot 里 `bootflow` 扫不到 | eMMC 里原厂 idbloader 完好时，BootROM 会先启它，根本到不了 SD 的 UEFI | 串口里 `mmc dev 0` 后 `bootflow scan -lb`；或 maskrom 清掉 eMMC 前 8 MiB |

---

## 8. 自检与验收

```bash
# 产物结构断言（务必在交付前跑）
FW=out/rk3588-easepi-r2-uefi-Release.img
[ "$(xxd -p -s 0x8000 -l 4 $FW)" = "524b4e53" ]   # RKNS
[ "$(xxd -p -s 0x100000 -l 4 $FW)" = "d00dfeed" ] # FIT 头 d0 0d fe ed
[ "$(wc -c < $FW)" -eq 6977536 ]

# 刷机盘
shasum -a 256 out/fxrecovery-easepi-r2-sd.img   # 应等于 5bb24215…
```

真机验收（**至今零次，第一个跑通的人要更新本节**）：

- [ ] 串口能出 UEFI 输出（1500000 8N1）
- [ ] UEFI 能点 HDMI
- [ ] GRUB 能从 FAT16 ESP 读到 `grub.cfg` 与 `boot/Image`
- [ ] 4 个 2.5G 网口里哪几个能在 UEFI 下起 UNDI
- [ ] initramfs 能靠 `fx-recovery.tag` 定位 ESP
- [ ] NVMe 识别 + `dd` 写入速度

---

## 9. 外部参考资料

| 资料 | 位置 | 注意 |
|:--|:--|:--|
| 上游 UEFI 移植全解（AI 风格、结构化） | `yifengyou/BDY_G98_RK3588` → `docs/适配记录/edk2_uefi.md`（1002 行） | **DSC 路径那段已过时**：它写 `Platform/Rockchip/RK3588/`，实际上游按厂商分目录 `Platform/Radxa/EasePiR2` |
| U-Boot 2026 适配排错 | 同上 → `uboot2026.md` | 含 `boot_targets=mmc1 mmc0 nvme scsi usb pxe dhcp spi`、`Trying fit image at 0x800 sector`（=1 MiB，印证 FIT@0x100000）、`rockusb 0 mtd 2` 直接进 maskrom |
| 刷机盘方案来源 | 本机 `../fx-recovery`（`easypi-r2-recovery`）、`../fw-assistant`（`easypi-r2-fw`） | 网页界面在 `fx-recovery/src/www/index.html` |
| 上游项目 | `edk2-porting/edk2-rk3588` README（457 行） | 平台列表、Flash layout、Memory Map |

> 截至 2026-10-22，上游与本仓库的 `edk2_uefi.md` 之外**没有** `AGENTS.md` / `CLAUDE.md` /
> `copilot-instructions.md` 一类约定文件；本文件是这套项目里第一份。
