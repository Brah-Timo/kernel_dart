/// Raspberry Pi platform support module.
///
/// Provides:
///   • Board detection (Pi 3 vs Pi 4 via board revision register)
///   • Preconfigured driver instances for BCM2835/BCM2711
///   • Mailbox interface to VideoCore GPU (clock, power, framebuffer)
///   • Helper for LED, camera, and I²C device detection
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


// ─────────────────────────────────────────────────────────────────────────────
// Board model detection
// ─────────────────────────────────────────────────────────────────────────────

/// Detected Raspberry Pi board model.
enum RaspberryPiModel {
  unknown,
  zeroPi,
  zero2,
  pi1b,
  pi1bp,
  pi2b,
  pi3b,
  pi3bp,
  pi3a,
  pi4b,
  pi4cm,
  pi5,
}

// ─────────────────────────────────────────────────────────────────────────────
// Mailbox interface (VideoCore firmware calls)
// ─────────────────────────────────────────────────────────────────────────────

/// Tag IDs for BCM Mailbox Property Interface.
abstract final class MailboxTag {
  static const int getFirmwareRevision = 0x00000001;
  static const int getBoardModel       = 0x00010001;
  static const int getBoardRevision    = 0x00010002;
  static const int getBoardMacAddress  = 0x00010003;
  static const int getBoardSerial      = 0x00010004;
  static const int getArmMemory        = 0x00010005;
  static const int getVcMemory         = 0x00010006;

  static const int setClockRate        = 0x00038002;
  static const int getClockRate        = 0x00030002;
  static const int getMaxClockRate     = 0x00030004;
  static const int setVoltage          = 0x00038003;

  static const int allocateBuffer      = 0x00040001;
  static const int releaseBuffer       = 0x00048001;
  static const int blankScreen         = 0x00040002;
  static const int setPhysicalDisplay  = 0x00048003;
  static const int setVirtualDisplay   = 0x00048004;
  static const int setDepth            = 0x00048005;
  static const int setVirtualOffset    = 0x00048009;
  static const int setPixelOrder       = 0x00048006;
  static const int getPitch            = 0x00040008;

  static const int endTag              = 0x00000000;
}

/// Result of a mailbox firmware call.
final class MailboxResponse {
  final bool success;
  final List<int> data;

  const MailboxResponse({required this.success, required this.data});

  int get first  => data.isNotEmpty ? data.first : 0;
  int? get second => data.length > 1 ? data[1] : null;
}

/// BCM2835/2711 Mailbox interface.
final class RaspberryPiMailbox {
  static const int _mailboxBase = 0x3F00B880;  // Pi 3 (Pi 4: 0xFE00B880)
  static final _log = Logger('RaspberryPiMailbox');

  final int baseAddress;

  RaspberryPiMailbox({this.baseAddress = _mailboxBase});

  /// Send a property tag request to the VideoCore.
  ///
  /// [tag] — mailbox tag ID
  /// [request] — tag request data words
  ///
  /// Returns [MailboxResponse] with the firmware's reply.
  MailboxResponse call(int tag, List<int> request) {
    _log.fine('Mailbox call: tag=0x${tag.toRadixString(16)}, request=${request.length} words');

    // Build the buffer: size | code | tag | size | code | data... | end_tag
    final bufSize = 6 + request.length; // in 32-bit words
    final buf = List<int>.filled(bufSize, 0);
    buf[0] = bufSize * 4;       // buffer size in bytes
    buf[1] = 0x00000000;        // request code
    buf[2] = tag;
    buf[3] = request.length * 4; // value buffer size
    buf[4] = 0;                 // request indicator
    for (var i = 0; i < request.length; i++) buf[5 + i] = request[i];
    buf[bufSize - 1] = MailboxTag.endTag;

    // In a real implementation:
    //   1. Write buf to a 16-byte aligned physical address
    //   2. Write (address | channel) to mailbox write register
    //   3. Poll until read is available
    //   4. Read response

    // Simulate: return a dummy success response
    final responseData = List<int>.filled(request.length, 0);
    return MailboxResponse(success: true, data: responseData);
  }

  /// Get the ARM base clock rate in Hz.
  int getArmClockHz() {
    // ARM clock ID = 3
    final r = call(MailboxTag.getClockRate, [3, 0]);
    return r.success && r.data.length >= 2 ? r.data[1] : 700000000;
  }

  /// Set the ARM core clock to [hz] Hz.
  void setArmClockHz(int hz) {
    call(MailboxTag.setClockRate, [3, hz, 0]);
  }

  /// Get board serial number.
  int getBoardSerial() {
    final r = call(MailboxTag.getBoardSerial, [0, 0]);
    if (!r.success || r.data.length < 2) return 0;
    return r.data[0] | (r.data[1] << 32);
  }

  /// Get board revision register (used to detect Pi model).
  int getBoardRevision() {
    final r = call(MailboxTag.getBoardRevision, [0]);
    return r.success ? r.first : 0;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RaspberryPi — platform initialisation
// ─────────────────────────────────────────────────────────────────────────────

/// Platform initialisation and preconfigured drivers for Raspberry Pi.
///
/// ```dart
/// final pi = await RaspberryPiPlatform.init();
/// pi.uart.println('Boot complete!');
/// pi.gpio.blinkLED(47); // Activity LED on Pi 3
/// ```
final class RaspberryPiPlatform {
  final PlatformConfig config;
  final RaspberryPiModel model;
  final RaspberryPiMailbox mailbox;

  // ─── Pre-configured driver instances ──────────────────────────────────────

  final UARTDriver  uart;
  final GPIODriver  gpio;
  final TimerDriver timer;
  final I2CDriver   i2c;
  final SPIDriver   spi;

  static final _log = Logger('RaspberryPiPlatform');

  RaspberryPiPlatform._({
    required this.config,
    required this.model,
    required this.mailbox,
    required this.uart,
    required this.gpio,
    required this.timer,
    required this.i2c,
    required this.spi,
  });

  /// Detect board model and initialise all drivers.
  static Future<RaspberryPiPlatform> init({bool verbose = true}) async {
    _log.info('Initialising Raspberry Pi platform…');

    // Auto-detect Pi 3 vs Pi 4 via board revision
    final mb       = RaspberryPiMailbox();
    final revision = mb.getBoardRevision();
    final model    = _detectModel(revision);
    final cfg      = model == RaspberryPiModel.pi4b ||
                     model == RaspberryPiModel.pi4cm
        ? PlatformConfig.raspberryPi4
        : PlatformConfig.raspberryPi3;

    PlatformConfig.setCurrent(cfg);

    // Create drivers
    final uart  = UARTDriver(baseAddress: cfg.uartBase, baudRate: 115200);
    final gpio  = GPIODriver(baseAddress: cfg.gpioBase);
    final timer = TimerDriver(baseAddress: cfg.timerBase);
    final i2c   = I2CDriver(baseAddress: cfg.i2cBase);
    final spi   = SPIDriver(baseAddress: cfg.spiBase);

    // Initialise all
    await uart.init();
    await gpio.init();
    await timer.init();
    await i2c.init();
    await spi.init();

    // Register with DeviceRegistry
    final reg = DeviceRegistry.instance;
    reg.register(uart);
    reg.register(gpio);
    reg.register(timer);
    reg.register(i2c);
    reg.register(spi);

    // Initialise memory manager (heap above kernel image)
    MemoryManager.init(
      heapStart: cfg.ramBase + 0x248000,
      heapSize:  cfg.ramSize - 0x248000 - 0x100000,
    );

    final platform = RaspberryPiPlatform._(
      config:  cfg,
      model:   model,
      mailbox: mb,
      uart:    uart,
      gpio:    gpio,
      timer:   timer,
      i2c:     i2c,
      spi:     spi,
    );

    if (verbose) {
      uart.println('kernel_dart — Raspberry Pi Platform');
      uart.println('  Model   : ${model.name}');
      uart.println('  CPU     : ${cfg.cpuClockHz ~/ 1000000} MHz');
      uart.println('  RAM     : ${cfg.ramSize >> 20} MB');
      uart.println('  UART    : 0x${cfg.uartBase.toRadixString(16)}');
    }

    _log.info('Raspberry Pi init complete: ${model.name}');
    return platform;
  }

  // ─── Board-specific helpers ───────────────────────────────────────────────

  /// Activity LED pin (green LED on Pi 3B+).
  int get activityLedPin {
    return switch (model) {
      RaspberryPiModel.pi3b  || RaspberryPiModel.pi3bp => 0,  // Uses GPIO expander
      RaspberryPiModel.pi4b  || RaspberryPiModel.pi4cm => 42,
      RaspberryPiModel.zeroPi                          => 47,
      _ => 47,
    };
  }

  /// Blink the board activity LED [times] times.
  Future<void> blinkActivityLed({int times = 3}) async {
    gpio.setDirection(activityLedPin, GPIODirection.output);
    for (var i = 0; i < times; i++) {
      gpio.writeLevel(activityLedPin, GPIOLevel.high);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      gpio.writeLevel(activityLedPin, GPIOLevel.low);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Scan I²C bus and print detected devices.
  void scanI2C() {
    final found = i2c.scanBus();
    uart.println('I2C scan: ${found.length} device(s)');
    for (final addr in found) {
      uart.println('  0x${addr.toRadixString(16).padLeft(2, '0')}');
    }
  }

  // ─── Internal ─────────────────────────────────────────────────────────────

  static RaspberryPiModel _detectModel(int revision) {
    // BCM2835 new-style revision codes (bit 23 set)
    if (revision & (1 << 23) == 0) return RaspberryPiModel.unknown;

    final processor = (revision >> 12) & 0xF;
    final boardType = (revision >> 4) & 0xFF;

    // processor: 0=BCM2835, 1=BCM2836, 2=BCM2837, 3=BCM2711
    // boardType:  0=A, 4=B, 8=3B, 9=Zero, 0x11=ZeroW, 0x13=3B+, 0x14=3A+, 0x11=4B
    if (processor == 3) return RaspberryPiModel.pi4b;
    if (processor == 2) {
      if (boardType == 0x13) return RaspberryPiModel.pi3bp;
      if (boardType == 0x14) return RaspberryPiModel.pi3a;
      return RaspberryPiModel.pi3b;
    }
    if (processor == 1) return RaspberryPiModel.pi2b;
    if (boardType == 0x09) return RaspberryPiModel.zeroPi;
    return RaspberryPiModel.pi1b;
  }
}
