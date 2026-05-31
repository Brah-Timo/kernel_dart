/// GPIO (General Purpose Input/Output) driver.
///
/// Supports:
///   • Pin direction (input / output / alternate function)
///   • Digital read / write
///   • Pull-up / pull-down resistors
///   • Interrupt-on-edge (rising / falling / both)
///   • Pin banking for multi-pin atomic operations
///
/// Register layout is compatible with BCM2835/2836/2837/2711 (Raspberry Pi).
// ignore_for_file: unused_field
library;

import 'package:logging/logging.dart';

import '../kernel/device_drivers.dart';
import '../runtime/ffi_bridge.dart';

// ─────────────────────────────────────────────────────────────────────────────
// GPIO register offsets (BCM2835 layout)
// ─────────────────────────────────────────────────────────────────────────────

abstract final class _BCM2835Gpio {
  // Function Select registers (3 bits per pin → 10 pins per register)
  static const int gpfsel0  = 0x00;  // pins 0–9
  static const int gpfsel1  = 0x04;  // pins 10–19
  static const int gpfsel2  = 0x08;  // pins 20–29
  static const int gpfsel3  = 0x0C;  // pins 30–39
  static const int gpfsel4  = 0x10;  // pins 40–49
  static const int gpfsel5  = 0x14;  // pins 50–53

  // Output Set / Clear registers
  static const int gpset0   = 0x1C;  // pins 0–31
  static const int gpset1   = 0x20;  // pins 32–53
  static const int gpclr0   = 0x28;  // pins 0–31
  static const int gpclr1   = 0x2C;  // pins 32–53

  // Level (input) registers
  static const int gplev0   = 0x34;  // pins 0–31
  static const int gplev1   = 0x38;  // pins 32–53

  // Event Detect Status registers
  static const int gpeds0   = 0x40;
  static const int gpeds1   = 0x44;

  // Rising/Falling edge detect enable
  static const int gpren0   = 0x4C;
  static const int gpren1   = 0x50;
  static const int gpfen0   = 0x58;
  static const int gpfen1   = 0x5C;

  // Pull-up/down enable
  static const int gppud    = 0x94;
  static const int gppudclk0 = 0x98;
  static const int gppudclk1 = 0x9C;

  // BCM2711 (RasPi 4) has different pull-up/down registers
  static const int gpio_pup_pdn_cntrl_reg0 = 0xE4;
  static const int gpio_pup_pdn_cntrl_reg1 = 0xE8;
  static const int gpio_pup_pdn_cntrl_reg2 = 0xEC;
  static const int gpio_pup_pdn_cntrl_reg3 = 0xF0;
}

// ─────────────────────────────────────────────────────────────────────────────
// GPIO enumerations
// ─────────────────────────────────────────────────────────────────────────────

/// Pin data direction.
enum GPIODirection { input, output }

/// Digital level of a pin.
enum GPIOLevel { low, high }

/// Alternate function selection (BCM layout).
enum GPIOFunction {
  input,          // 000
  output,         // 001
  alt0,           // 100
  alt1,           // 101
  alt2,           // 110
  alt3,           // 111
  alt4,           // 011
  alt5,           // 010
}

/// Pull resistor configuration.
enum GPIOPull { none, pullUp, pullDown }

/// Edge trigger for GPIO interrupts.
enum GPIOEdge { rising, falling, both, none }

// ─────────────────────────────────────────────────────────────────────────────
// GPIO pin event
// ─────────────────────────────────────────────────────────────────────────────

/// An edge event detected on a GPIO pin.
final class GpioPinEvent {
  final int pin;
  final GPIOLevel level;
  final DateTime timestamp;

  const GpioPinEvent({
    required this.pin,
    required this.level,
    required this.timestamp,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// GPIODriver
// ─────────────────────────────────────────────────────────────────────────────

/// BCM2835-compatible GPIO driver (Raspberry Pi).
///
/// ```dart
/// final gpio = GPIODriver(baseAddress: 0x3F200000);
/// await gpio.init();
///
/// gpio.setDirection(17, GPIODirection.output);
/// gpio.writeLevel(17, GPIOLevel.high);
///
/// gpio.setDirection(18, GPIODirection.input);
/// gpio.setPull(18, GPIOPull.pullUp);
/// final level = gpio.readLevel(18);
/// ```
final class GPIODriver extends DeviceDriver {
  final int _base;

  /// Interrupt callbacks keyed by pin number.
  final Map<int, List<void Function(GpioPinEvent)>> _listeners = {};

  static final _log = Logger('GPIODriver');

  GPIODriver({required int baseAddress}) : _base = baseAddress;

  @override
  DeviceInfo get info => DeviceInfo(
        name:        'gpio0',
        description: 'BCM2835 GPIO Controller',
        type:        DeviceType.gpio,
        baseAddress: _base,
        irqNumber:   49,
      );

  @override
  Future<void> init() async {
    _log.info('GPIO init at 0x${_base.toRadixString(16)}');
    status = DeviceStatus.ready;
  }

  @override
  Future<void> cleanup() async {
    _listeners.clear();
    status = DeviceStatus.removed;
  }

  // ─── Direction ────────────────────────────────────────────────────────────

  /// Set [pin] to [direction] (input or output).
  void setDirection(int pin, GPIODirection direction) {
    _validatePin(pin);
    setFunction(pin, direction == GPIODirection.output
        ? GPIOFunction.output
        : GPIOFunction.input);
  }

  /// Set [pin] to a specific alternate function.
  void setFunction(int pin, GPIOFunction fn) {
    _validatePin(pin);
    final regOffset = _gpfselForPin(pin);
    final shift     = (pin % 10) * 3;
    final fnCode    = _fnCode(fn);

    MMIO.modify32(_base + regOffset, (v) {
      return (v & ~(0x7 << shift)) | (fnCode << shift);
    });
    _log.fine('GPIO$pin function → ${fn.name}');
  }

  // ─── Write ────────────────────────────────────────────────────────────────

  /// Set [pin] output to [level].
  void writeLevel(int pin, GPIOLevel level) {
    _validatePin(pin);
    final regOffset = level == GPIOLevel.high
        ? (pin < 32 ? _BCM2835Gpio.gpset0 : _BCM2835Gpio.gpset1)
        : (pin < 32 ? _BCM2835Gpio.gpclr0 : _BCM2835Gpio.gpclr1);
    final bit = 1 << (pin % 32);
    MMIO.write32(_base + regOffset, bit);
  }

  /// Toggle [pin] output.
  void toggle(int pin) {
    final current = readLevel(pin);
    writeLevel(pin, current == GPIOLevel.high ? GPIOLevel.low : GPIOLevel.high);
  }

  // ─── Read ─────────────────────────────────────────────────────────────────

  /// Read the current digital level of [pin].
  GPIOLevel readLevel(int pin) {
    _validatePin(pin);
    final regOffset = pin < 32 ? _BCM2835Gpio.gplev0 : _BCM2835Gpio.gplev1;
    final level     = MMIO.read32(_base + regOffset);
    return (level >> (pin % 32)) & 1 == 1 ? GPIOLevel.high : GPIOLevel.low;
  }

  // ─── Pull resistors ───────────────────────────────────────────────────────

  /// Configure the pull resistor for [pin] (BCM2835 sequence).
  void setPull(int pin, GPIOPull pull) {
    _validatePin(pin);

    // Step 1: write GPPUD
    MMIO.write32(_base + _BCM2835Gpio.gppud, _pullCode(pull));

    // Step 2: wait 150 cycles (simulated with no-op)
    for (var i = 0; i < 150; i++) CPU.nop();

    // Step 3: set clock bit for pin
    final clkReg = pin < 32 ? _BCM2835Gpio.gppudclk0 : _BCM2835Gpio.gppudclk1;
    MMIO.write32(_base + clkReg, 1 << (pin % 32));

    // Step 4: wait 150 cycles
    for (var i = 0; i < 150; i++) CPU.nop();

    // Step 5: clear GPPUD and clock register
    MMIO.write32(_base + _BCM2835Gpio.gppud, 0);
    MMIO.write32(_base + clkReg, 0);

    _log.fine('GPIO$pin pull → ${pull.name}');
  }

  // ─── Edge detection / interrupts ─────────────────────────────────────────

  /// Enable edge detection on [pin].
  void enableEdgeDetect(int pin, GPIOEdge edge) {
    _validatePin(pin);
    final bitMask = 1 << (pin % 32);

    if (edge == GPIOEdge.rising || edge == GPIOEdge.both) {
      final reg = pin < 32 ? _BCM2835Gpio.gpren0 : _BCM2835Gpio.gpren1;
      MMIO.setBits(_base + reg, bitMask);
    }
    if (edge == GPIOEdge.falling || edge == GPIOEdge.both) {
      final reg = pin < 32 ? _BCM2835Gpio.gpfen0 : _BCM2835Gpio.gpfen1;
      MMIO.setBits(_base + reg, bitMask);
    }
    _log.fine('GPIO$pin edge detect → ${edge.name}');
  }

  /// Disable edge detection on [pin].
  void disableEdgeDetect(int pin) {
    final bitMask = ~(1 << (pin % 32));
    MMIO.modify32(_base + _BCM2835Gpio.gpren0, (v) => v & bitMask);
    MMIO.modify32(_base + _BCM2835Gpio.gpfen0, (v) => v & bitMask);
  }

  /// Register a callback for pin edge events.
  void onEdge(int pin, void Function(GpioPinEvent) callback) {
    _listeners.putIfAbsent(pin, () => []).add(callback);
  }

  /// Remove all callbacks for [pin].
  void clearEdgeListeners(int pin) => _listeners.remove(pin);

  @override
  void handleIrq(int irqNumber) {
    // Check event detect status registers
    for (final bank in [0, 1]) {
      final reg  = bank == 0 ? _BCM2835Gpio.gpeds0 : _BCM2835Gpio.gpeds1;
      final eds  = MMIO.read32(_base + reg);

      if (eds == 0) continue;

      // Clear events
      MMIO.write32(_base + reg, eds);

      // Notify listeners
      for (var bit = 0; bit < 32; bit++) {
        if (eds >> bit & 1 == 0) continue;
        final pin   = bank * 32 + bit;
        final level = readLevel(pin);
        final event = GpioPinEvent(pin: pin, level: level, timestamp: DateTime.now());

        _listeners[pin]?.forEach((cb) => cb(event));
      }
    }
  }

  // ─── High-level helpers ───────────────────────────────────────────────────

  /// Blink [pin] [times] times with [delay] between transitions.
  Future<void> blinkLED(
    int pin, {
    int times                    = 1,
    Duration onDuration          = const Duration(milliseconds: 500),
    Duration offDuration         = const Duration(milliseconds: 500),
    bool initDirection           = true,
  }) async {
    if (initDirection) setDirection(pin, GPIODirection.output);

    for (var i = 0; i < times; i++) {
      writeLevel(pin, GPIOLevel.high);
      await Future<void>.delayed(onDuration);
      writeLevel(pin, GPIOLevel.low);
      await Future<void>.delayed(offDuration);
    }
  }

  /// Set multiple pins from a bitmask in a single register write.
  ///
  /// [pinMask] is a bitmask of pins 0–31 to set HIGH;
  /// all other pins in [pinMask] range are set LOW.
  void writeBank0(int highMask, int lowMask) {
    if (highMask != 0) MMIO.write32(_base + _BCM2835Gpio.gpset0, highMask);
    if (lowMask  != 0) MMIO.write32(_base + _BCM2835Gpio.gpclr0, lowMask);
  }

  // ─── Internal helpers ─────────────────────────────────────────────────────

  void _validatePin(int pin) {
    if (pin < 0 || pin > 53) {
      throw ArgumentError('Invalid GPIO pin: $pin (must be 0–53)');
    }
  }

  int _fnCode(GPIOFunction fn) => switch (fn) {
        GPIOFunction.input  => 0, // 0b000
        GPIOFunction.output => 1, // 0b001
        GPIOFunction.alt0   => 4, // 0b100
        GPIOFunction.alt1   => 5, // 0b101
        GPIOFunction.alt2   => 6, // 0b110
        GPIOFunction.alt3   => 7, // 0b111
        GPIOFunction.alt4   => 3, // 0b011
        GPIOFunction.alt5   => 2, // 0b010
      };

  int _pullCode(GPIOPull pull) => switch (pull) {
        GPIOPull.none     => 0,
        GPIOPull.pullDown => 1,
        GPIOPull.pullUp   => 2,
      };
}

// Compute GPFSEL register offset for a given pin number
int _gpfselForPin(int pin) => (pin ~/ 10) * 4;
