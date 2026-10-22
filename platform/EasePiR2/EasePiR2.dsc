## @file
#
#  EasePi R2 (LinkEase, RK3588) platform description.
#
#  Board facts derived from the vendor device tree rk3588-easepi-r2.dtb:
#    - PMIC         : RK806 on SPI2 (feb20000) CS0
#    - External DC/DC: RK860x @ i2c0 0x42 / 0x43 (CPUB01 / CPUB23)
#    - RTC          : HY M8563 @ i2c6 0x51
#    - UART console : UART2 (feb50000) @ 1500000n8
#    - NVMe         : pcie3x4 (fe150000) domain 0, dedicated PCIe3 PHY
#    - Ethernet     : 4x RTL8125 2.5G
#                       pcie3x2   (fe160000) domain 1
#                       pcie2x1l0 (fe170000) domain 2
#                       pcie2x1l1 (fe180000) domain 3
#                       pcie2x1l2 (fe190000) domain 4
#    - All three Naneng combo PHYs drive PCIe here. The vendor DTB also leaves
#      sata1/sata2 enabled, but they share the very same PHYs, so the four
#      Ethernet ports take priority and SATA is not available.
#    - GMAC         : both controllers disabled in the vendor DTB
#    - Display      : HDMI0 + DP0 (HDMI1 and USBDP0 disabled, USBDP1 enabled)
#
#  SPDX-License-Identifier: BSD-2-Clause-Patent
#
##

################################################################################
#
# Defines Section - statements that will be processed to create a Makefile.
#
################################################################################
[Defines]
  PLATFORM_NAME                  = EasePiR2
  PLATFORM_VENDOR                = Radxa
  PLATFORM_GUID                  = bae7742e-390f-4960-ba2d-f623dc437783
  PLATFORM_VERSION               = 0.1
  DSC_SPECIFICATION              = 0x00010019
  OUTPUT_DIRECTORY               = Build/$(PLATFORM_NAME)
  VENDOR_DIRECTORY               = Platform/$(PLATFORM_VENDOR)
  PLATFORM_DIRECTORY             = $(VENDOR_DIRECTORY)/$(PLATFORM_NAME)
  SUPPORTED_ARCHITECTURES        = AARCH64
  BUILD_TARGETS                  = DEBUG|RELEASE
  SKUID_IDENTIFIER               = DEFAULT
  FLASH_DEFINITION               = Silicon/Rockchip/RK3588/RK3588.fdf
  RK_PLATFORM_FVMAIN_MODULES     = $(PLATFORM_DIRECTORY)/$(PLATFORM_NAME).Modules.fdf.inc

  # Both GMAC controllers are disabled on this board
  DEFINE RK3588_GMAC_ENABLE = FALSE

  #
  # HYM8563 RTC support
  # I2C location configured by PCDs below.
  #
  DEFINE RK_RTC8563_ENABLE = TRUE

  #
  # RK3588-based platform
  #
!include Silicon/Rockchip/RK3588/RK3588Platform.dsc.inc

################################################################################
#
# Library Class section - list of all Library Classes needed by this Platform.
#
################################################################################

[LibraryClasses.common]
  RockchipPlatformLib|$(PLATFORM_DIRECTORY)/Library/RockchipPlatformLib/RockchipPlatformLib.inf

################################################################################
#
# Pcd Section - list of all EDK II PCD Entries defined by this Platform.
#
################################################################################

[PcdsFixedAtBuild.common]
  # SMBIOS platform config
  gRockchipTokenSpaceGuid.PcdPlatformName|"EasePi R2"
  gRockchipTokenSpaceGuid.PcdPlatformVendorName|"LinkEase"
  gRockchipTokenSpaceGuid.PcdFamilyName|"EasePi"
  gRockchipTokenSpaceGuid.PcdProductUrl|"https://www.linkease.com/"
  gRockchipTokenSpaceGuid.PcdDeviceTreeName|"rk3588-easepi-r2"

  # I2C
  #   i2c0: two RK860x regulators (0x42, 0x43)
  #   i2c6: HY M8563 RTC (0x51)
  # A third RK860x sits on i2c1 0x42; it is deliberately left out of the
  # managed set so firmware never reprograms a rail whose role is unknown.
  gRockchipTokenSpaceGuid.PcdI2cSlaveAddresses|{ 0x42, 0x43, 0x51 }
  gRockchipTokenSpaceGuid.PcdI2cSlaveBuses|{ 0x0, 0x0, 0x6 }
  gRockchipTokenSpaceGuid.PcdI2cSlaveBusesRuntimeSupport|{ FALSE, FALSE, TRUE }
  gRockchipTokenSpaceGuid.PcdRk860xRegulatorAddresses|{ 0x42, 0x43 }
  gRockchipTokenSpaceGuid.PcdRk860xRegulatorBuses|{ 0x0, 0x0 }
  gRockchipTokenSpaceGuid.PcdRk860xRegulatorTags|{ $(SCMI_CLK_CPUB01), $(SCMI_CLK_CPUB23) }
  gPcf8563RealTimeClockLibTokenSpaceGuid.PcdI2cSlaveAddress|0x51
  gRockchipTokenSpaceGuid.PcdRtc8563Bus|0x6

  #
  # PCIe/SATA/USB Combo PIPE PHY support flags and default values
  #
  # All three combo PHYs feed PCIe: dom2/dom3/dom4 carry the 2.5G NICs.
  #
  gRK3588TokenSpaceGuid.PcdComboPhy0Switchable|FALSE
  gRK3588TokenSpaceGuid.PcdComboPhy1Switchable|FALSE
  gRK3588TokenSpaceGuid.PcdComboPhy2Switchable|FALSE
  gRK3588TokenSpaceGuid.PcdComboPhy0ModeDefault|$(COMBO_PHY_MODE_PCIE)
  gRK3588TokenSpaceGuid.PcdComboPhy1ModeDefault|$(COMBO_PHY_MODE_PCIE)
  gRK3588TokenSpaceGuid.PcdComboPhy2ModeDefault|$(COMBO_PHY_MODE_PCIE)

  #
  # USB/DP Combo PHY support flags and default values
  #
  # usbdp0 (fed80000) disabled, usbdp1 (fed90000) enabled.
  # DP0 comes from the dedicated hdptx PHY (fed60000).
  #
  gRK3588TokenSpaceGuid.PcdUsbDpPhy0Supported|FALSE
  gRK3588TokenSpaceGuid.PcdUsbDpPhy1Supported|TRUE
  gRK3588TokenSpaceGuid.PcdDp0LaneMux|{ 0x2, 0x3 }
  gRK3588TokenSpaceGuid.PcdDp1LaneMux|{ 0x0 }

  #
  # I2S
  #
  gRK3588TokenSpaceGuid.PcdI2S0Supported|TRUE

  #
  # No on-board PWM fan in the vendor device tree (all PWM nodes disabled)
  #
  gRK3588TokenSpaceGuid.PcdHasOnBoardFanOutput|FALSE

  #
  # Display support flags and default values
  #
  gRK3588TokenSpaceGuid.PcdDisplayConnectors|{CODE({
    VOP_OUTPUT_IF_HDMI0,
    VOP_OUTPUT_IF_DP0
  })}

################################################################################
#
# Components Section - list of all EDK II Modules needed by this Platform.
#
################################################################################
[Components.common]
  # ACPI Support
  $(PLATFORM_DIRECTORY)/AcpiTables/AcpiTables.inf

  # Device Tree Support
  $(PLATFORM_DIRECTORY)/DeviceTree/Vendor.inf

  # Splash screen logo
  $(VENDOR_DIRECTORY)/Drivers/LogoDxe/LogoDxe.inf

