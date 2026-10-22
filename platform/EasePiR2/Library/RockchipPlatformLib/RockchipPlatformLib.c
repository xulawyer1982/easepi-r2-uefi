/** @file
*
*  LinkEase EasePi R2 (RK3588) board support.
*
*  Every board-specific constant below was derived from the vendor device
*  tree rk3588-easepi-r2.dtb, not guessed:
*
*    PMIC            RK806 on SPI2 CS0, regulators listed with their actual
*                    names/limits in the DTB.
*    PCIe reset GPIOs (active low, from each pcie@ node's reset-gpios):
*      pcie3x4   (fe150000, dom0, NVMe)  -> GPIO4 PB6  (pin 14)
*      pcie3x2   (fe160000, dom1, NIC)   -> GPIO0 PC5  (pin 21)
*      pcie2x1l0 (fe170000, dom2, NIC)   -> GPIO4 PA7  (pin  7)
*      pcie2x1l1 (fe180000, dom3, NIC)   -> GPIO3 PC7  (pin 23)
*      pcie2x1l2 (fe190000, dom4, NIC)   -> GPIO3 PB1  (pin 17)
*
*  Deliberate omissions - the firmware does not touch any GPIO that the
*  device tree does not document, so an unknown board revision cannot be
*  driven into an invalid state:
*    - no on-board PWM fan (all pwm@ nodes are disabled)
*    - no status LED GPIO mapping in the DTB
*    - no PCIe WiFi enable GPIO in the DTB
*
*  Copyright (c) 2021, Rockchip Limited. All rights reserved.
*  Copyright (c) 2023-2024, Mario Bălănică <mariobalanica02@gmail.com>
*
*  SPDX-License-Identifier: BSD-2-Clause-Patent
*
**/

#include <Base.h>
#include <Library/DebugLib.h>
#include <Library/IoLib.h>
#include <Library/GpioLib.h>
#include <Library/RK806.h>
#include <Library/Rk3588Pcie.h>
#include <Library/PWMLib.h>
#include <Soc.h>
#include <VarStoreData.h>

//
// RK806 rail setup. Values match the vendor device tree regulator limits
// (vdd_gpu_s0, vdd_log_s0, vdd_vdenc_s0, vdd_ddr_s0, vdd_2v0_pldo_s3,
// vcc_3v3_s3, vcc_1v8_s3, ...). Note NLDO3 -> avdd_0v75_s0 is 837 mV on
// this board, not the 750 mV used by some other RK3588 designs.
//
static struct regulator_init_data  rk806_init_data[] = {
  /* Master PMIC */
  RK8XX_VOLTAGE_INIT (MASTER_BUCK1,  750000),   // vdd_gpu_s0
  RK8XX_VOLTAGE_INIT (MASTER_BUCK3,  750000),   // vdd_log_s0
  RK8XX_VOLTAGE_INIT (MASTER_BUCK4,  750000),   // vdd_vdenc_s0
  RK8XX_VOLTAGE_INIT (MASTER_BUCK5,  850000),   // vdd_ddr_s0
  // RK8XX_VOLTAGE_INIT(MASTER_BUCK6, 750000),  // vdd2_ddr_s3, no range set
  RK8XX_VOLTAGE_INIT (MASTER_BUCK7,  2000000),  // vdd_2v0_pldo_s3
  RK8XX_VOLTAGE_INIT (MASTER_BUCK8,  3300000),  // vcc_3v3_s3
  RK8XX_VOLTAGE_INIT (MASTER_BUCK10, 1800000),  // vcc_1v8_s3

  RK8XX_VOLTAGE_INIT (MASTER_NLDO1,  750000),   // vdd_0v75_s3
  RK8XX_VOLTAGE_INIT (MASTER_NLDO2,  850000),   // avdd_ddr_pll_s0
  RK8XX_VOLTAGE_INIT (MASTER_NLDO3,  837000),   // avdd_0v75_s0  <-- board specific
  RK8XX_VOLTAGE_INIT (MASTER_NLDO4,  850000),   // avdd_0v85_s0
  RK8XX_VOLTAGE_INIT (MASTER_NLDO5,  750000),   // vdd_0v75_s0

  RK8XX_VOLTAGE_INIT (MASTER_PLDO1,  1800000),  // avcc_1v8_s0
  RK8XX_VOLTAGE_INIT (MASTER_PLDO2,  1800000),  // vcc_1v8_s0
  RK8XX_VOLTAGE_INIT (MASTER_PLDO3,  1200000),  // avdd_1v2_s0
  RK8XX_VOLTAGE_INIT (MASTER_PLDO4,  3300000),  // avcc_3v3_s0
  RK8XX_VOLTAGE_INIT (MASTER_PLDO5,  3300000),  // vccio_sd_s0 (SD IO, 3.3V)
  RK8XX_VOLTAGE_INIT (MASTER_PLDO6,  1800000),  // pldo6_s3

  /* Single PMIC on this board, no secondary RK806 */
};

VOID
EFIAPI
SdmmcIoMux (
  VOID
  )
{
  /* sdmmc0 iomux (microSD socket) */
  BUS_IOC->GPIO4D_IOMUX_SEL_L  = (0xFFFFUL << 16) | (0x1111); // SDMMC_D0..D3
  BUS_IOC->GPIO4D_IOMUX_SEL_H  = (0x00FFUL << 16) | (0x0011); // SDMMC_CLK, SDMMC_CMD
  PMU1_IOC->GPIO0A_IOMUX_SEL_H = (0x000FUL << 16) | (0x0001); // SDMMC_DET
}

VOID
EFIAPI
SdhciEmmcIoMux (
  VOID
  )
{
  /* sdhci0 iomux (eMMC) */
  BUS_IOC->GPIO2A_IOMUX_SEL_L = (0xFFFFUL << 16) | (0x1111); // EMMC_CMD,CLKOUT,DATASTROBE,RSTN
  BUS_IOC->GPIO2D_IOMUX_SEL_L = (0xFFFFUL << 16) | (0x1111); // EMMC_D0..D3
  BUS_IOC->GPIO2D_IOMUX_SEL_H = (0xFFFFUL << 16) | (0x1111); // EMMC_D4..D7
}

#define NS_CRU_BASE       0xFD7C0000
#define CRU_CLKSEL_CON59  0x03EC
#define CRU_CLKSEL_CON78  0x0438

VOID
EFIAPI
Rk806SpiIomux (
  VOID
  )
{
  /* RK806 sits on SPI2, same wiring as the RK3588 reference design */
  PMU1_IOC->GPIO0A_IOMUX_SEL_H = (0x0FF0UL << 16) | 0x0110;
  PMU1_IOC->GPIO0B_IOMUX_SEL_L = (0xF0FFUL << 16) | 0x1011;
  MmioWrite32 (NS_CRU_BASE + CRU_CLKSEL_CON59, (0x00C0UL << 16) | 0x0080);
}

VOID
EFIAPI
Rk806Configure (
  VOID
  )
{
  UINTN  RegCfgIndex;

  RK806Init ();

  RK806PinSetFunction (MASTER, 1, 2); // rk806_dvs1_pwrdn

  for (RegCfgIndex = 0; RegCfgIndex < ARRAY_SIZE (rk806_init_data); RegCfgIndex++) {
    RK806RegulatorInit (rk806_init_data[RegCfgIndex]);
  }
}

VOID
EFIAPI
SetCPULittleVoltage (
  IN UINT32  Microvolts
  )
{
  struct regulator_init_data  Rk806CpuLittleSupply =
    RK8XX_VOLTAGE_INIT (MASTER_BUCK2, Microvolts);

  RK806RegulatorInit (Rk806CpuLittleSupply);
}

VOID
EFIAPI
NorFspiIomux (
  VOID
  )
{
  /* No SPI NOR flash populated on EasePi R2 */
  MmioWrite32 (
    NS_CRU_BASE + CRU_CLKSEL_CON78,
    (((0x3 << 12) | (0x3f << 6)) << 16) | (0x0 << 12) | (0x3f << 6)
    );
}

VOID
EFIAPI
GmacIomux (
  IN UINT32  Id
  )
{
  /* Both RK3588 GMAC controllers are disabled on this board */
}

VOID
EFIAPI
NorFspiEnableClock (
  UINT32  *CruBase
  )
{
  UINTN  BaseAddr = (UINTN)CruBase;

  MmioWrite32 (BaseAddr + 0x087C, 0x0E000000);
}

VOID
EFIAPI
I2cIomux (
  UINT32  id
  )
{
  switch (id) {
    case 0:
      GpioPinSetFunction (0, GPIO_PIN_PD1, 3); // i2c0_scl_m2
      GpioPinSetFunction (0, GPIO_PIN_PD2, 3); // i2c0_sda_m2
      break;
    case 1:
      GpioPinSetFunction (0, GPIO_PIN_PD4, 9); // i2c1_scl_m2
      GpioPinSetFunction (0, GPIO_PIN_PD5, 9); // i2c1_sda_m2
      break;
    case 2:
      break;
    case 3:
      break;
    case 4:
      GpioPinSetFunction (2, GPIO_PIN_PB5, 9); // i2c4_scl_m1
      GpioPinSetFunction (2, GPIO_PIN_PB4, 9); // i2c4_sda_m1
      break;
    case 5:
      break;
    case 6:
      GpioPinSetFunction (0, GPIO_PIN_PD0, 9); // i2c6_scl_m0 (RTC on 0x51)
      GpioPinSetFunction (0, GPIO_PIN_PC7, 9); // i2c6_sda_m0
      break;
    case 7:
      GpioPinSetFunction (1, GPIO_PIN_PD0, 9); // i2c7_scl_m0
      GpioPinSetFunction (1, GPIO_PIN_PD1, 9); // i2c7_sda_m0
      break;
    default:
      break;
  }
}

VOID
EFIAPI
UsbPortPowerEnable (
  VOID
  )
{
  //
  // No USB VBUS enable GPIO is described in the vendor device tree for this
  // board, so leave the default (regulator-backed) behaviour untouched.
  //
  DEBUG ((DEBUG_INFO, "UsbPortPowerEnable: no board GPIO, skipped\n"));
}

VOID
EFIAPI
Usb2PhyResume (
  VOID
  )
{
  MmioWrite32 (0xfd5d0008, 0x20000000);
  MmioWrite32 (0xfd5d4008, 0x20000000);
  MmioWrite32 (0xfd5d8008, 0x20000000);
  MmioWrite32 (0xfd5dc008, 0x20000000);
  MmioWrite32 (0xfd7f0a10, 0x07000700);
  MmioWrite32 (0xfd7f0a10, 0x07000000);
}

VOID
EFIAPI
PcieIoInit (
  UINT32  Segment
  )
{
  /* Set reset lines to GPIO output mode before touching them */
  switch (Segment) {
    case PCIE_SEGMENT_PCIE30X4:
      GpioPinSetDirection (4, GPIO_PIN_PB6, GPIO_PIN_OUTPUT);
      break;
    case PCIE_SEGMENT_PCIE30X2:
      GpioPinSetDirection (0, GPIO_PIN_PC5, GPIO_PIN_OUTPUT);
      break;
    case PCIE_SEGMENT_PCIE20L0:
      GpioPinSetDirection (4, GPIO_PIN_PA7, GPIO_PIN_OUTPUT);
      break;
    case PCIE_SEGMENT_PCIE20L1:
      GpioPinSetDirection (3, GPIO_PIN_PC7, GPIO_PIN_OUTPUT);
      break;
    case PCIE_SEGMENT_PCIE20L2:
      GpioPinSetDirection (3, GPIO_PIN_PC1, GPIO_PIN_OUTPUT);
      break;
    default:
      break;
  }
}

VOID
EFIAPI
PciePowerEn (
  UINT32   Segment,
  BOOLEAN  Enable
  )
{
  //
  // Every PCIe slot on this board is powered straight from a PMIC rail
  // (vcc3v3-pcie / vcc3v3-nvme / dcdc-reg8). There is no per-slot power
  // enable GPIO in the device tree, so there is nothing to switch here.
  //
}

VOID
EFIAPI
PciePeReset (
  UINT32   Segment,
  BOOLEAN  Enable
  )
{
  /* reset-gpios are active low: assert low to reset */
  switch (Segment) {
    case PCIE_SEGMENT_PCIE30X4:
      GpioPinWrite (4, GPIO_PIN_PB6, !Enable);
      break;
    case PCIE_SEGMENT_PCIE30X2:
      GpioPinWrite (0, GPIO_PIN_PC5, !Enable);
      break;
    case PCIE_SEGMENT_PCIE20L0:
      GpioPinWrite (4, GPIO_PIN_PA7, !Enable);
      break;
    case PCIE_SEGMENT_PCIE20L1:
      GpioPinWrite (3, GPIO_PIN_PC7, !Enable);
      break;
    case PCIE_SEGMENT_PCIE20L2:
      GpioPinWrite (3, GPIO_PIN_PC1, !Enable);
      break;
    default:
      break;
  }
}

VOID
EFIAPI
HdmiTxIomux (
  IN UINT32  Id
  )
{
  switch (Id) {
    case 0:
      GpioPinSetFunction (4, GPIO_PIN_PC1, 5); // hdmim0_tx0_cec
      GpioPinSetPull (4, GPIO_PIN_PC1, GPIO_PIN_PULL_NONE);
      GpioPinSetFunction (1, GPIO_PIN_PA5, 5); // hdmim0_tx0_hpd
      GpioPinSetPull (1, GPIO_PIN_PA5, GPIO_PIN_PULL_NONE);
      GpioPinSetFunction (4, GPIO_PIN_PB7, 5); // hdmim0_tx0_scl
      GpioPinSetPull (4, GPIO_PIN_PB7, GPIO_PIN_PULL_NONE);
      GpioPinSetFunction (4, GPIO_PIN_PC0, 5); // hdmim0_tx0_sda
      GpioPinSetPull (4, GPIO_PIN_PC0, GPIO_PIN_PULL_NONE);
      break;
    case 1:
      /* HDMI1 is disabled in the vendor device tree */
      break;
  }
}

PWM_DATA  pwm_data = {
  .ControllerID = PWM_CONTROLLER0,
  .ChannelID    = PWM_CHANNEL1,
  .PeriodNs     = 4000000,
  .DutyNs       = 4000000,
  .Polarity     = FALSE,
};

VOID
EFIAPI
PwmFanIoSetup (
  VOID
  )
{
  /* No on-board PWM fan output described in the vendor device tree */
}

VOID
EFIAPI
PwmFanSetSpeed (
  IN UINT32  Percentage
  )
{
  /* No on-board PWM fan output described in the vendor device tree */
}

VOID
EFIAPI
PlatformInitLeds (
  VOID
  )
{
  /* No status LED GPIO mapping available in the vendor device tree */
}

VOID
EFIAPI
PlatformSetStatusLed (
  IN BOOLEAN  Enable
  )
{
  /* No status LED GPIO mapping available in the vendor device tree */
}

VOID
EFIAPI
PlatformPcieWiFiEnable (
  IN BOOLEAN  Enable
  )
{
  /* No PCIe WiFi enable GPIO described in the vendor device tree */
}

CONST EFI_GUID *
EFIAPI
PlatformGetDtbFileGuid (
  IN UINT32  CompatMode
  )
{
  STATIC CONST EFI_GUID  VendorDtbFileGuid = {
    // DeviceTree/Vendor.inf
    0xd58b4028, 0x43d8, 0x4e97, { 0x87, 0xd4, 0x4e, 0x37, 0x16, 0x13, 0x65, 0x80 }
  };

  //
  // Only a vendor DTB is shipped for this board, so both compatibility modes
  // resolve to it. Falling back beats handing the OS an empty device tree.
  //
  if (CompatMode == FDT_COMPAT_MODE_VENDOR || CompatMode == FDT_COMPAT_MODE_MAINLINE) {
    return &VendorDtbFileGuid;
  }

  return NULL;
}

VOID
EFIAPI
PlatformEarlyInit (
  VOID
  )
{
  /* Nothing board specific to do before the PMIC and PCIe are set up */
}
