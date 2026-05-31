/// Device driver framework for the kernel_dart microkernel.
///
/// Provides:
///   • [DeviceDriver] base class with lifecycle hooks
///   • [DeviceRegistry] for dynamic driver registration / lookup
///   • [DeviceType] enumeration
///   • [DriverBus] for device enumeration and hot-plug events
library;

import 'package:logging/logging.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DeviceType
// ─────────────────────────────────────────────────────────────────────────────

/// Category of a hardware device.
enum DeviceType {
  uart,
  gpio,
  timer,
  spi,
  i2c,
  ethernet,
  usb,
  storage,
  display,
  audio,
  watchdog,
  pwm,
  adc,
  dac,
  rtc,
  unknown,
}

// ─────────────────────────────────────────────────────────────────────────────
// DeviceStatus
// ─────────────────────────────────────────────────────────────────────────────

/// Current operational status of a device.
enum DeviceStatus {
  uninitialised,
  initializing,
  ready,
  busy,
  error,
  suspended,
  removed,
}

// ─────────────────────────────────────────────────────────────────────────────
// DeviceInfo — metadata
// ─────────────────────────────────────────────────────────────────────────────

/// Static metadata about a device.
final class DeviceInfo {
  final String name;
  final String description;
  final DeviceType type;
  final int baseAddress;
  final int? irqNumber;
  final int? dmaChannel;
  final Map<String, String> properties;

  const DeviceInfo({
    required this.name,
    required this.description,
    required this.type,
    required this.baseAddress,
    this.irqNumber,
    this.dmaChannel,
    this.properties = const {},
  });

  @override
  String toString() =>
      'DeviceInfo(name=$name, type=${type.name}, '
      'base=0x${baseAddress.toRadixString(16)})';
}

// ─────────────────────────────────────────────────────────────────────────────
// DeviceDriver — abstract base
// ─────────────────────────────────────────────────────────────────────────────

/// Abstract base class for all kernel_dart device drivers.
///
/// Every driver must implement [init] and [cleanup].
/// Optional hooks: [suspend], [resume], [handleIrq].
abstract base class DeviceDriver {
  /// Static device metadata.
  DeviceInfo get info;

  /// Current operational status.
  DeviceStatus status = DeviceStatus.uninitialised;

  static final _log = Logger('DeviceDriver');

  /// Initialise the hardware device.
  ///
  /// Called once during kernel boot (or when the device is hot-plugged).
  /// Should configure hardware registers and register IRQ handlers.
  Future<void> init();

  /// Release all resources and return the device to a safe state.
  Future<void> cleanup();

  /// Suspend the device (power-saving mode).
  Future<void> suspend() async {
    status = DeviceStatus.suspended;
    _log.fine('${info.name}: suspended');
  }

  /// Resume the device from suspended state.
  Future<void> resume() async {
    status = DeviceStatus.ready;
    _log.fine('${info.name}: resumed');
  }

  /// Handle a hardware interrupt for this device.
  ///
  /// Override in drivers that need to respond to IRQs.
  void handleIrq(int irqNumber) {
    _log.fine('${info.name}: unhandled IRQ $irqNumber');
  }

  /// Memory-mapped I/O read (32-bit register).
  int readRegister(int offset) {
    // In a real implementation this would use FFI or inline assembly.
    // Here we return 0 as a safe default.
    return 0;
  }

  /// Memory-mapped I/O write (32-bit register).
  void writeRegister(int offset, int value) {
    // In a real implementation: *(volatile uint32_t*)(base + offset) = value
    _log.fine('${info.name}: MMIO write offset=0x${offset.toRadixString(16)} value=0x${value.toRadixString(16)}');
  }

  @override
  String toString() => 'Driver(${info.name}, ${status.name})';
}

// ─────────────────────────────────────────────────────────────────────────────
// DeviceRegistry — global driver lookup
// ─────────────────────────────────────────────────────────────────────────────

/// Central registry mapping device names to their [DeviceDriver] instances.
final class DeviceRegistry {
  static final DeviceRegistry instance = DeviceRegistry._();
  DeviceRegistry._();

  final Map<String, DeviceDriver> _drivers = {};

  static final _log = Logger('DeviceRegistry');

  // ─── Registration ─────────────────────────────────────────────────────────

  /// Register [driver] under its [DeviceInfo.name].
  void register(DeviceDriver driver) {
    _drivers[driver.info.name] = driver;
    _log.info('Registered driver: ${driver.info}');
  }

  /// Unregister a driver by name.
  void unregister(String name) {
    _drivers.remove(name);
    _log.info('Unregistered driver: $name');
  }

  // ─── Lookup ───────────────────────────────────────────────────────────────

  /// Find a driver by name.
  T? get<T extends DeviceDriver>(String name) =>
      _drivers[name] as T?;

  /// Find all drivers of a given [DeviceType].
  List<T> getByType<T extends DeviceDriver>(DeviceType type) =>
      _drivers.values
          .whereType<T>()
          .where((d) => d.info.type == type)
          .toList();

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  /// Initialise all registered drivers in registration order.
  Future<void> initAll() async {
    _log.info('Initialising ${_drivers.length} drivers…');

    for (final driver in _drivers.values) {
      _log.info('  init: ${driver.info.name}');
      driver.status = DeviceStatus.initializing;
      try {
        await driver.init();
        driver.status = DeviceStatus.ready;
      } on Exception catch (e) {
        driver.status = DeviceStatus.error;
        _log.severe('  FAILED: ${driver.info.name}: $e');
      }
    }

    _log.info('Driver initialisation complete.');
  }

  /// Suspend all ready drivers (e.g. before entering low-power mode).
  Future<void> suspendAll() async {
    for (final driver in _drivers.values) {
      if (driver.status == DeviceStatus.ready) await driver.suspend();
    }
  }

  /// Resume all suspended drivers.
  Future<void> resumeAll() async {
    for (final driver in _drivers.values) {
      if (driver.status == DeviceStatus.suspended) await driver.resume();
    }
  }

  // ─── Diagnostics ──────────────────────────────────────────────────────────

  /// Dump a formatted driver status table.
  String dumpStatus() {
    final buf = StringBuffer('=== Device Driver Status ===\n');
    for (final d in _drivers.values) {
      final pad = d.info.name.padRight(20);
      buf.writeln('  $pad ${d.status.name.padRight(14)} ${d.info.type.name}');
    }
    buf.write('============================');
    return buf.toString();
  }

  /// List of all registered device names.
  List<String> get names => List.unmodifiable(_drivers.keys);
}

// ─────────────────────────────────────────────────────────────────────────────
// DriverBus — enumeration & hot-plug
// ─────────────────────────────────────────────────────────────────────────────

/// Simulates a hardware bus (e.g. AXI, APB, PCI) for device enumeration.
final class DriverBus {
  final String name;
  final List<DeviceDriver> _attached = [];
  final List<void Function(DeviceDriver, bool)> _hotplugListeners = [];

  static final _log = Logger('DriverBus');

  DriverBus(this.name);

  /// Attach [driver] to this bus.
  void attach(DeviceDriver driver) {
    _attached.add(driver);
    DeviceRegistry.instance.register(driver);
    _log.info('$name: attached ${driver.info.name}');
    _notifyHotplug(driver, attached: true);
  }

  /// Detach a driver by name.
  Future<void> detach(String driverName) async {
    final driver = _attached.where((d) => d.info.name == driverName).firstOrNull;
    if (driver == null) return;

    await driver.cleanup();
    driver.status = DeviceStatus.removed;
    _attached.remove(driver);
    DeviceRegistry.instance.unregister(driverName);
    _log.info('$name: detached $driverName');
    _notifyHotplug(driver, attached: false);
  }

  /// Register a hot-plug listener.
  ///
  /// [listener] is called with `(driver, true)` on attach and `(driver, false)` on detach.
  void addHotplugListener(void Function(DeviceDriver, bool) listener) {
    _hotplugListeners.add(listener);
  }

  void _notifyHotplug(DeviceDriver driver, {required bool attached}) {
    for (final l in _hotplugListeners) {
      l(driver, attached);
    }
  }

  /// List attached device names.
  List<String> get attachedNames =>
      _attached.map((d) => d.info.name).toList();
}
