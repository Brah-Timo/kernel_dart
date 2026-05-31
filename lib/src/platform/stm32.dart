/// STM32 platform support (STM32F4xx / STM32H7xx).
library;

import 'package:logging/logging.dart';
import '../config/platform_config.dart';
import '../drivers/uart_driver.dart';
import '../drivers/gpio_driver.dart';
import '../drivers/timer_driver.dart';
import '../drivers/i2c_driver.dart';
import '../drivers/spi_driver.dart';
import '../kernel/device_drivers.dart';
import '../kernel/memory_manager.dart';
import '../runtime/ffi_bridge.dart';

/// STM32 GPIO port (A–K).
enum STM32GpioPort { a, b, c, d, e, f, g, h, i, j, k }

/// STM32 clock source.
enum STM32ClockSource { hsi, hse, pll }

/// RCC (Reset and Clock Control) configuration for STM32.
final class STM32RCCConfig {
  /// System clock target frequency in Hz.
  final int sysclkHz;

  /// Clock source.
  final STM32ClockSource source;

  /// HSE crystal frequency (required if source == hse or pll with HSE).
  final int? hseHz;

  const STM32RCCConfig({
    this.sysclkHz = 168000000,
    this.source   = STM32ClockSource.pll,
    this.hseHz,
  });
}

/// STM32 platform initialisation.
final class STM32Platform {
  final PlatformConfig config;
  final STM32RCCConfig clockConfig;

  final UARTDriver  uart;
  final GPIODriver  gpio;
  final TimerDriver timer;
  final I2CDriver   i2c;
  final SPIDriver   spi;

  static final _log = Logger('STM32Platform');

  STM32Platform._({
    required this.config,
    required this.clockConfig,
    required this.uart,
    required this.gpio,
    required this.timer,
    required this.i2c,
    required this.spi,
  });

  /// Initialise STM32F4 platform.
  static Future<STM32Platform> initF4({
    STM32RCCConfig clockConfig = const STM32RCCConfig(),
  }) async {
    final cfg = PlatformConfig.stm32f4;
    PlatformConfig.setCurrent(cfg);
    return _init(cfg, clockConfig);
  }

  /// Initialise STM32H7 platform.
  static Future<STM32Platform> initH7({
    STM32RCCConfig clockConfig = const STM32RCCConfig(sysclkHz: 480000000),
  }) async {
    final cfg = PlatformConfig.stm32h7;
    PlatformConfig.setCurrent(cfg);
    return _init(cfg, clockConfig);
  }

  static Future<STM32Platform> _init(
    PlatformConfig cfg,
    STM32RCCConfig clockConfig,
  ) async {
    _log.info('Initialising STM32 platform (${cfg.name})…');

    // Configure clocks
    await _configureClock(cfg, clockConfig);

    final uart  = UARTDriver(baseAddress: cfg.uartBase, baudRate: 115200,
        config: UARTConfig(peripheralClockHz: cfg.peripheralClockHz));
    final gpio  = GPIODriver(baseAddress: cfg.gpioBase);
    final timer = TimerDriver(baseAddress: cfg.timerBase, clockHz: cfg.peripheralClockHz);
    final i2c   = I2CDriver(baseAddress: cfg.i2cBase,
        config: I2CConfig(peripheralClockHz: cfg.peripheralClockHz));
    final spi   = SPIDriver(baseAddress: cfg.spiBase,
        config: SPIConfig(peripheralClockHz: cfg.peripheralClockHz));

    await uart.init();
    await gpio.init();
    await timer.init();
    await i2c.init();
    await spi.init();

    DeviceRegistry.instance
      ..register(uart)
      ..register(gpio)
      ..register(timer)
      ..register(i2c)
      ..register(spi);

    MemoryManager.init(
      heapStart: cfg.ramBase + 0x8000,
      heapSize:  cfg.ramSize - 0x8000,
    );

    _log.info('STM32 init complete: SYSCLK=${clockConfig.sysclkHz ~/ 1000000} MHz');

    return STM32Platform._(
      config:      cfg,
      clockConfig: clockConfig,
      uart:        uart,
      gpio:        gpio,
      timer:       timer,
      i2c:         i2c,
      spi:         spi,
    );
  }

  /// Configure the STM32 RCC for the target clock speed.
  static Future<void> _configureClock(PlatformConfig cfg, STM32RCCConfig clk) async {
    _log.fine('Configuring STM32 RCC: ${clk.sysclkHz ~/ 1000000} MHz via ${clk.source.name}');
    // Real implementation: configure PLL multipliers/dividers in RCC registers
    // Enable HSE or HSI, configure PLL, switch SYSCLK source, update flash latency
  }

  // ─── GPIO helpers (STM32-specific) ───────────────────────────────────────

  /// Enable the AHB1 peripheral clock for [port].
  void enableGpioClock(STM32GpioPort port) {
    const rccAhb1enr = 0x40023830;
    MMIO.setBits(rccAhb1enr, 1 << port.index);
  }

  /// Compute GPIO port base address.
  int gpioPortBase(STM32GpioPort port) =>
      0x40020000 + port.index * 0x400;

  /// Set a pin on a specific GPIO port.
  void setPin(STM32GpioPort port, int pin, GPIOLevel level) {
    final base = gpioPortBase(port);
    // STM32 BSRR register: bit n → set, bit n+16 → reset
    final bit = level == GPIOLevel.high ? 1 << pin : 1 << (pin + 16);
    MMIO.write32(base + 0x18, bit); // BSRR offset = 0x18
  }
}
