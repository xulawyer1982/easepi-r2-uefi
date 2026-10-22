# EasePi R2 — EDK2 UEFI 固件 + 网页刷机盘

给 **LinkEase EasePi R2（RK3588）** 移植的 EDK2 UEFI 固件。刷进 **SD 卡或 eMMC** 后，
这块板子就从 `U-Boot + extlinux` 变成 **标准 UEFI 平台**：

```
BootROM → idblock(SPL+ATF) → EDK2 UEFI → OS
```

本仓库产出**两样东西**：

| 产物 | 大小 | 用途 |
|---|---|---|
| `rk3588-easepi-r2-uefi-Release.img` | 6.65 MiB | 纯 UEFI 固件（含 idblock + ATF + UEFI），写 0x8000 |
| `fxrecovery-easepi-r2-sd.img` | 105 MiB | **完整刷机盘**：UEFI + GRUB + Linux recovery + 网页刷机程序 |

完整刷机盘的启动链：

```
BootROM → idblock(SPL+ATF) → EDK2 UEFI → GRUB → Linux(6.18.18-trim)
        → initramfs → Go 网页服务 → 浏览器选盘选镜像 → dd 写 NVMe/SATA
```

插卡上电，浏览器打开它打印的地址，就能往 SSD 里装系统。**RK3588 BootROM 不能从
NVMe/SATA 直接引导**，所以这张卡要一直插着当引导介质，SSD 只放系统。

然后它能干 U-Boot 干不了的事：

- 引导 **标准 UEFI 系统**：Debian / Ubuntu arm64 的 ISO 安装盘、GRUB、EFI stub 内核
- 引导 **Windows on ARM**（驱动残缺，仅尝鲜）
- 4 个 2.5G 网口、NVMe、USB 在 UEFI 里有 **UNDI/块设备**支持，可以直接 PXE / HTTP 装系统
- 从 UEFI Shell 直接 dd 固件到 NVMe（自带 `RK3588_NOR_FLASH.img` 就能自我更新）

> 本仓库只放 **板级移植**，UEFI 本体来自 [edk2-porting/edk2-rk3588](https://github.com/edk2-porting/edk2-rk3588)。
> 构建时由 CI 拉上游 + 叠加本仓库的 overlay，所以这里没有几十万行第三方代码。

---

## 为什么需要这块板子的移植

上游 `edk2-rk3588` 支持 24 块板，**没有 EasePi R2**。这块板子有几个地方和 Rock 5B 这类"标准"
RK3588 板不同，直接刷别人的固件有烧板风险（上游 README 明确警告电压可能不同）：

| 项目 | Rock 5B | **EasePi R2** |
|---|---|---|
| 以太网 | 1× RTL8125 2.5G | **4× RTL8125 2.5G** |
| PCIe 5 个控制器的用途 | 30x4→NVMe，20L2→网卡 | **30x4→NVMe，其余 4 个各挂一个网口** |
| Combo PHY 分配 | 0/1→PCIe，2→USB3 | **0/1/2 全部→PCIe**（SATA 因此不可用） |
| GMAC | 关闭 | 关闭（两个都 disabled） |
| NLDO3 (`avdd_0v75_s0`) | 750 mV | **837 mV** |
| 板载 PWM 风扇 | 有 | **无**（DTB 里 PWM 全 disabled） |
| 状态灯 / WiFi 使能 GPIO | 有 | **DTB 未描述，固件不碰** |

所有板级参数不是猜的，是从厂商设备树 `rk3588-easepi-r2.dtb`
（`compatible = "linkease,easepi-r2", "easepi,r2", "rockchip,rk3588"`）里逐项读出来的。

### PCIe 复位引脚（全部取自 DTB 的 `reset-gpios`，低有效）

| 控制器 | 地址 | domain | 用途 | 复位 GPIO |
|---|---|---|---|---|
| pcie3x4 | fe150000 | 0 | NVMe | GPIO4 **PB6** |
| pcie3x2 | fe160000 | 1 | 2.5G 网口 | GPIO0 **PC5** |
| pcie2x1l0 | fe170000 | 2 | 2.5G 网口 | GPIO4 **PA7** |
| pcie2x1l1 | fe180000 | 3 | 2.5G 网口 | GPIO3 **PC7** |
| pcie2x1l2 | fe190000 | 4 | 2.5G 网口 | GPIO3 **PC1** |

### 固件刻意"不碰"的东西

没有在设备树里写明的 GPIO，固件一律不驱动。这样即便买到硬件小改版的板子，也不会因为
一个猜错的引脚把某个电源轨拉进非法状态。具体是：

- 不操作任何 USB VBUS 使能脚（板子上没有对应描述）
- 不操作状态灯
- 不操作 PCIe WiFi 使能脚
- 不操作 PWM 风扇
- 第三个 RK860（位于 i2c1 0x42）**不纳入管理** —— 它的作用未知，固件不去改它的电压

---

## 构建

CI 自动构建（推 `main` 或手动 `workflow_dispatch`），产物是 artifact。

本地构建需要 Linux（或 WSL / Docker）：

```bash
sudo apt install -y acpica-tools binutils-aarch64-linux-gnu build-essential \
  device-tree-compiler gettext git gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
  python3 python3-pyelftools uuid-dev

git clone --depth 1 https://github.com/edk2-porting/edk2-rk3588.git up
cd up
git config submodule."devicetree/mainline/upstream".active false
git submodule update --init --depth 1 \
  edk2 edk2-platforms edk2-non-osi arm-trusted-firmware misc/rkbin

# 叠加本仓库
cp -a ../platform/EasePiR2/. edk2-rockchip/Platform/Radxa/EasePiR2/
cp ../devicetree/vendor/rk3588-easepi-r2.dtb devicetree/vendor/
cp ../configs/easepi-r2.conf configs/

./build.sh --device easepi-r2 --release Release
# 产物：RK3588_NOR_FLASH.img（8 MiB）
```

---

## 烧录

**只写固件部分**（保留卡上已有分区和系统）：

```bash
# 注意：目标盘整段会被覆盖，务必核对设备名
sudo dd if=RK3588_NOR_FLASH.img of=/dev/rdiskN bs=512 skip=64 seek=64 conv=notrunc
```

`skip=64` 跳过镜像自带的那份 GPT（对 SD/eMMC 没用），`seek=64` 写到 0x8000 ——
BootROM 就是这个偏移找 idblock 的。

**整盘烧**（卡上不要别的数据时，用 balenaEtcher / RPi Imager 直接选 img 也行）：

```bash
sudo dd if=RK3588_NOR_FLASH.img of=/dev/rdiskN bs=1m
```

### 闪存布局（固件期望的固定偏移，别改）

| 地址 | 大小 | 内容 |
|---|---|---|
| 0x00000000 | 0x4400 | GPT（仅 SPI NOR 用得到） |
| 0x00008000 | — | IDBlock = DDR init + SPL |
| 0x00100000 | 0x500000 | BL33_AP_UEFI FV（UEFI 本体） |
| 0x007C0000 | 0x10000 | NV 变量存储 |
| 0x007D0000 | 0x10000 | NV FTW working |
| 0x007E0000 | 0x10000 | NV FTW spare |

---

## 第一次上机要注意

1. **串口是唯一的诊断窗口**：`ttyS2`（UART2，`0xfeb50000`）**1500000 8N1**。
   HDMI 也可能出画面，但 UEFI 的启动日志、DTB 覆盖错误、PCIe 训练失败都只在串口里。
2. **RK3588 BootROM 不支持从 NVMe/SATA 引导**。SSD 上的系统永远需要一个中间引导 ——
   也就是这张 SD 卡（或 eMMC 里的这份固件）。
3. 本固件**没有 SPI NOR 版本**，因为 EasePi R2 板上就没焊 SPI NOR。
4. 救砖：按住 Maskrom 键上电 → `rkdeveloptool` / RKDevTool 重新灌。

## 状态

- [x] 板级描述、设备树、PCIe/PMIC/RTC 配置
- [x] CI 编译通过（run #3）
- [x] 镜像结构自检：`idblock@0x8000 = RKNS`、`FIT@0x100000 = d00dfeed`
- [ ] 真机串口启动验证
- [ ] 4× 2.5G 网口 UNDI 驱动验证
- [ ] NVMe 识别与引导验证

**尚未在真机上验证过任何一项。** 这是第一版移植，预期需要串口日志迭代。

### 当前固件

| 项目 | 值 |
|---|---|
| 文件名 | `rk3588-easepi-r2-uefi-Release.img` |
| 大小 | 6,977,536 bytes（6.65 MiB） |
| sha256 | `dd53e16153449dc31f2d96221402435c142ed110af0b599cd4e1a40d03068cf8` |
| 构建 | GitHub Actions run #3，`Release` / GCC |

仓库根目录的 `flash-sd.command` 双击即可写卡（自动找可移除盘、写完回读校验）。

## 许可

板级移植部分：BSD-2-Clause-Patent（与上游一致）。UEFI 本体遵循上游各自许可。
