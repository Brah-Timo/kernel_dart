/// ESP32 platform support (Xtensa LX6 dual-core, 240 MHz).
///
/// Note: kernel_dart currently targets ARM and x86 for AOT compilation.
/// ESP32 support is provided as a platform configuration + driver preset
/// for future Xtensa AOT support.
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

/// ESP32 GPIO matrix mapping (simplified).
abstract final class ESP32Gpio {
  // Common user pins
  static const int gpio2  = 2;   // Onboard LED (most boards)
  static const int gpio4  = 4;
  static const int gpio5  = 5;
  static const int gpio12 = 12;
  static const int gpio13 = 13;
  static const int gpio14 = 14;
  static const int gpio15 = 15;
  static const int gpio16 = 16;  // U2RXD
  static const int gpio17 = 17;  // U2TXD
  static const int gpio21 = 21;  // SDA (default I2C)
  static const int gpio22 = 22;  // SCL (default I2C)
  static const int gpio23 = 23;  // MOSI (default SPI)
  static const int gpio18 = 18;  // SCK  (default SPI)
  static const int gpio19 = 19;  // MISO (default SPI)
  static const int gpio5_ss = 5; // SS   (default SPI)
}

/// ESP32 WiFi modes.
enum ESP32WifiMode { off, sta, ap, apSta }

/// ESP32 platform initialisation.
final class ESP32Platform {
  final PlatformConfig config;

  final UARTDriver  uart;
  final GPIODriver  gpio;
  final TimerDriver timer;
  final I2CDriver   i2c;
  final SPIDriver   spi;

  static final _log = Logger('ESP32Platform');

  ESP32Platform._({
    required this.config,
    required this.uart,
    required this.gpio,
    required this.timer,
    required this.i2c,
    required this.spi,
  });

  static Future<ESP32Platform> init() async {
    final cfg = PlatformConfig.esp32;
    PlatformConfig.setCurrent(cfg);
    _log.info('Initialising ESP32 platform…');

    // Initialise ROM boot stub (normally done by ESP-IDF first-stage bootloader)
    await _initRomBootStub();

    final uart  = UARTDriver(baseAddress: cfg.uartBase, baudRate: 115200);
    final gpio  = GPIODriver(baseAddress: cfg.gpioBase);
    final timer = TimerDriver(baseAddress: cfg.timerBase, clockHz: 80000000);
    final i2c   = I2CDriver(baseAddress: cfg.i2cBase);
    final spi   = SPIDriver(baseAddress: cfg.spiBase);

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
      heapStart: cfg.ramBase + 0x4000,
      heapSize:  cfg.ramSize - 0x4000,
    );

    _log.info('ESP32 init complete.');
    return ESP32Platform._(
      config: cfg,
      uart:   uart,
      gpio:   gpio,
      timer:  timer,
      i2c:    i2c,
      spi:    spi,
    );
  }

  // ─── ESP32-specific helpers ───────────────────────────────────────────────

  /// Configure CPU speed (80 / 160 / 240 MHz).
  void setCpuFrequency(int mhz) {
    assert(mhz == 80 || mhz == 160 || mhz == 240, 'Invalid CPU frequency: $mhz MHz');
    _log.info('ESP32 CPU frequency → $mhz MHz');
    // Real: configure RTC_CNTL_SOC_CLK_SEL and PLL
  }

  /// Put the ESP32 into deep sleep for [duration].
  void deepSleep(Duration duration) {
    _log.info('ESP32 deep sleep: ${duration.inSeconds} s');
    // Real: esp_sleep_enable_timer_wakeup + esp_deep_sleep_start
    MMIO.write32(0x3FF48080, duration.inMicroseconds); // RTC_CNTL_TIMER5_REG
    MMIO.setBits (0x3FF48094, 1 << 9);                 // enable timer wakeup
    MMIO.setBits (0x3FF48000, 1 << 31);                // start deep sleep
  }

  /// Return available heap (simulated).
  int freeHeap() => MemoryManager.instance.getMemoryStats().freeMemory;

  static Future<void> _initRomBootStub() async {
    // Disable watchdog timers enabled by boot ROM
    const rtcWdtFeed  = 0x3FF48090;
    const timerWdtFeed = 0x3FF5F064;
    MMIO.write32(rtcWdtFeed,   0);
    MMIO.write32(timerWdtFeed, 0);

    // Enable cache (normally done by IDF)
    // Enable PSRAM if available
  }
}
