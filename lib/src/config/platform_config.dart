/// Platform-specific hardware configuration.
///
/// Provides base addresses and clock frequencies for every supported board.
library;

import '../compiler/dart_compiler.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PlatformConfig
// ─────────────────────────────────────────────────────────────────────────────

/// Hardware configuration for a target board.
final class PlatformConfig {
  final String name;
  final String description;
  final TargetArchitecture architecture;
  final int uartBase;
  final int gpioBase;
  final int timerBase;
  final int i2cBase;
  final int spiBase;
  final int gicBase;
  final int ramBase;
  final int ramSize;
  final int cpuClockHz;
  final int peripheralClockHz;

  const PlatformConfig({
    required this.name,
    required this.description,
    required this.architecture,
    required this.uartBase,
    required this.gpioBase,
    required this.timerBase,
    required this.i2cBase,
    required this.spiBase,
    required this.gicBase,
    required this.ramBase,
    required this.ramSize,
    required this.cpuClockHz,
    required this.peripheralClockHz,
  });

  // ─── Known platform presets ───────────────────────────────────────────────

  static const PlatformConfig raspberryPi3 = PlatformConfig(
    name:              'raspberry_pi_3',
    description:       'Raspberry Pi 3 Model B (BCM2837, Cortex-A53)',
    architecture:      TargetArchitecture.arm64,
    uartBase:          0x3F201000,
    gpioBase:          0x3F200000,
    timerBase:         0x3F003000,
    i2cBase:           0x3F804000,
    spiBase:           0x3F204000,
    gicBase:           0x3F00B200,
    ramBase:           0x00000000,
    ramSize:           0x40000000, // 1 GB
    cpuClockHz:        1200000000, // 1.2 GHz
    peripheralClockHz: 250000000,  // 250 MHz
  );

  static const PlatformConfig raspberryPi4 = PlatformConfig(
    name:              'raspberry_pi_4',
    description:       'Raspberry Pi 4 Model B (BCM2711, Cortex-A72)',
    architecture:      TargetArchitecture.arm64,
    uartBase:          0xFE201000,
    gpioBase:          0xFE200000,
    timerBase:         0xFE003000,
    i2cBase:           0xFE804000,
    spiBase:           0xFE204000,
    gicBase:           0xFF841000,
    ramBase:           0x00000000,
    ramSize:           0x100000000, // 4 GB (may be 1/2/4/8 GB)
    cpuClockHz:        1500000000,  // 1.5 GHz
    peripheralClockHz: 200000000,
  );

  static const PlatformConfig stm32f4 = PlatformConfig(
    name:              'stm32f4',
    description:       'STM32F4xx (ARM Cortex-M4)',
    architecture:      TargetArchitecture.arm,
    uartBase:          0x40011000, // USART1
    gpioBase:          0x40020000, // GPIOA
    timerBase:         0x40000000, // TIM2
    i2cBase:           0x40005400, // I2C1
    spiBase:           0x40013000, // SPI1
    gicBase:           0xE000E000, // NVIC (ARM Cortex-M)
    ramBase:           0x20000000,
    ramSize:           0x00020000, // 128 KB SRAM
    cpuClockHz:        168000000,  // 168 MHz max
    peripheralClockHz: 84000000,   // APB2 / 2
  );

  static const PlatformConfig stm32h7 = PlatformConfig(
    name:              'stm32h7',
    description:       'STM32H7xx (ARM Cortex-M7)',
    architecture:      TargetArchitecture.arm,
    uartBase:          0x40011000,
    gpioBase:          0x58020000,
    timerBase:         0x40000000,
    i2cBase:           0x40005400,
    spiBase:           0x40013000,
    gicBase:           0xE000E000,
    ramBase:           0x20000000,
    ramSize:           0x00080000, // 512 KB DTCM
    cpuClockHz:        480000000,  // 480 MHz max
    peripheralClockHz: 240000000,
  );

  static const PlatformConfig esp32 = PlatformConfig(
    name:              'esp32',
    description:       'ESP32 (Xtensa LX6, dual-core 240 MHz)',
    architecture:      TargetArchitecture.arm, // placeholder (Xtensa not yet supported)
    uartBase:          0x3FF40000, // UART0
    gpioBase:          0x3FF44000,
    timerBase:         0x3FF5F000,
    i2cBase:           0x3FF53000,
    spiBase:           0x3FF42000,
    gicBase:           0x3FF00000, // DPORT (interrupt controller)
    ramBase:           0x3FFB0000,
    ramSize:           0x00050000, // 320 KB internal SRAM
    cpuClockHz:        240000000,
    peripheralClockHz: 80000000,
  );

  static const PlatformConfig genericArm64 = PlatformConfig(
    name:              'generic_arm64',
    description:       'Generic AArch64 board (QEMU virt machine)',
    architecture:      TargetArchitecture.arm64,
    uartBase:          0x09000000, // PL011 UART0 on QEMU virt
    gpioBase:          0x09010000,
    timerBase:         0x09020000,
    i2cBase:           0x09030000,
    spiBase:           0x09040000,
    gicBase:           0x08000000, // GICv2 distributor
    ramBase:           0x40000000,
    ramSize:           0x40000000, // 1 GB
    cpuClockHz:        1000000000,
    peripheralClockHz: 24000000,
  );

  // ─── Static accessors ─────────────────────────────────────────────────────

  /// Current platform (set at boot from [BootInfo]).
  static PlatformConfig _current = genericArm64;

  static PlatformConfig get current => _current;

  static void setCurrent(PlatformConfig config) {
    _current = config;
  }

  /// Look up a platform by name string.
  static PlatformConfig fromString(String name) => switch (name.toLowerCase()) {
        'raspberry_pi'   ||
        'raspberry_pi_3' ||
        'raspberrypi3'   => raspberryPi3,
        'raspberry_pi_4' ||
        'raspberrypi4'   => raspberryPi4,
        'stm32'          ||
        'stm32f4'        => stm32f4,
        'stm32h7'        => stm32h7,
        'esp32'          => esp32,
        'generic_arm'    ||
        'generic_arm64'  ||
        'x86_64'         => genericArm64,
        _ => throw ArgumentError('Unknown platform: $name'),
      };

  // ─── YAML serialisation ───────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'name':               name,
        'description':        description,
        'architecture':       architecture.name,
        'uart_base':          '0x${uartBase.toRadixString(16)}',
        'gpio_base':          '0x${gpioBase.toRadixString(16)}',
        'timer_base':         '0x${timerBase.toRadixString(16)}',
        'i2c_base':           '0x${i2cBase.toRadixString(16)}',
        'spi_base':           '0x${spiBase.toRadixString(16)}',
        'gic_base':           '0x${gicBase.toRadixString(16)}',
        'ram_base':           '0x${ramBase.toRadixString(16)}',
        'ram_size_mb':        ramSize >> 20,
        'cpu_clock_mhz':      cpuClockHz ~/ 1000000,
        'peripheral_clock_mhz': peripheralClockHz ~/ 1000000,
      };

  @override
  String toString() =>
      'PlatformConfig($name, ${architecture.name}, '
      'uart=0x${uartBase.toRadixString(16)}, '
      'ram=${ramSize >> 20} MB)';
}
