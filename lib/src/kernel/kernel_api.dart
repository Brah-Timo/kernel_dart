/// Public kernel API — the single facade through which Dart applications
/// interact with the kernel_dart microkernel.
///
/// Provides:
///   • Kernel initialisation and shutdown
///   • Access to memory, scheduler, interrupt handler and device registry
///   • Busy-wait helpers ([BusyWait])
///   • Kernel panic (fatal error handler)
library;

import 'package:logging/logging.dart';

import 'memory_manager.dart';
import 'scheduler.dart';
import 'interrupt_handler.dart';
import 'device_drivers.dart';
import '../bootloader/boot_protocol.dart';

export 'memory_manager.dart';
export 'scheduler.dart';
export 'interrupt_handler.dart';
export 'device_drivers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// KernelVersion
// ─────────────────────────────────────────────────────────────────────────────

/// Semantic version of the kernel_dart kernel.
final class KernelVersion {
  static const int major = 1;
  static const int minor = 0;
  static const int patch = 0;
  static const String label = '';

  static String get string =>
      '$major.$minor.$patch${label.isEmpty ? '' : '-$label'}';
}

// ─────────────────────────────────────────────────────────────────────────────
// KernelConfig — boot-time configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Tunable parameters for kernel initialisation.
final class KernelConfig {
  final int heapStart;
  final int heapSize;
  final double gcThreshold;
  final AllocationStrategy memStrategy;
  final SchedulingPolicy schedPolicy;
  final bool enableUart;
  final bool enableGpio;
  final bool enableTimers;

  const KernelConfig({
    this.heapStart   = 0x00248000,
    this.heapSize    = 0x04000000,   // 64 MB
    this.gcThreshold = 0.10,
    this.memStrategy = AllocationStrategy.bestFit,
    this.schedPolicy = SchedulingPolicy.priorityBased,
    this.enableUart  = true,
    this.enableGpio  = true,
    this.enableTimers = true,
  });

  /// Override heap with values derived from a [BootInfo] structure.
  factory KernelConfig.fromBootInfo(BootInfo bootInfo) {
    final region = bootInfo.largestFreeRegion;
    return KernelConfig(
      heapStart:  region?.physicalStart ?? 0x00248000,
      heapSize:   region?.sizeBytes     ?? 0x04000000,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// KernelApi — main facade
// ─────────────────────────────────────────────────────────────────────────────

/// Central kernel façade.
///
/// Call [KernelApi.boot] at the start of `main()` to initialise all
/// subsystems, then use the named getters to access them.
///
/// ```dart
/// void main() {
///   KernelApi.boot(KernelConfig(heapSize: 0x02000000));
///   KernelApi.uart.print('Hello, bare metal!\r\n');
///
///   KernelApi.scheduler.addTask('blink', () => blinkLed());
///   KernelApi.kernel.run();
/// }
/// ```
final class KernelApi {
  static KernelApi? _instance;
  static final _log = Logger('KernelApi');

  // ─── Sub-systems ──────────────────────────────────────────────────────────

  final MemoryManager    memory;
  final TaskScheduler    scheduler;
  final InterruptHandler irq;
  final DeviceRegistry   devices;

  bool _running = false;

  KernelApi._({
    required this.memory,
    required this.scheduler,
    required this.irq,
    required this.devices,
  });

  /// Global kernel instance (available after [boot]).
  static KernelApi get instance {
    assert(_instance != null, 'KernelApi not booted. Call KernelApi.boot() first.');
    return _instance!;
  }

  // ─── Boot ─────────────────────────────────────────────────────────────────

  /// Initialise all kernel subsystems.
  ///
  /// Must be called once before any kernel API is used.
  static Future<KernelApi> boot([KernelConfig config = const KernelConfig()]) async {
    _log.info('kernel_dart v${KernelVersion.string} booting…');
    _log.info('  heap:    0x${config.heapStart.toRadixString(16)} + ${config.heapSize >> 20} MB');
    _log.info('  gc:      threshold=${(config.gcThreshold * 100).toStringAsFixed(0)}%');
    _log.info('  sched:   ${config.schedPolicy.name}');

    // 1. Memory manager
    final mm = MemoryManager.init(
      heapStart:   config.heapStart,
      heapSize:    config.heapSize,
      gcThreshold: config.gcThreshold,
      strategy:    config.memStrategy,
    );

    // 2. Scheduler
    final sched = TaskScheduler.instance;
    sched.policy = config.schedPolicy;

    // 3. Interrupt handler
    final irq = InterruptHandler.instance;
    irq.enableInterrupts();

    // 4. Device registry — drivers are registered by platform support code
    final devices = DeviceRegistry.instance;
    await devices.initAll();

    _instance = KernelApi._(
      memory:    mm,
      scheduler: sched,
      irq:       irq,
      devices:   devices,
    );

    _log.info('kernel_dart boot complete.');
    _log.info(mm.getMemoryStats().toString());

    return _instance!;
  }

  // ─── Main loop ────────────────────────────────────────────────────────────

  /// Enter the kernel's main scheduling loop.
  ///
  /// Returns only when [shutdown] is called.
  void run() {
    _log.info('Entering scheduler main loop…');
    _running = true;

    while (_running) {
      // 1. Dispatch any pending (deferred) IRQs
      irq.processPending();

      // 2. Run one scheduler tick
      scheduler.tick();
    }

    _log.info('Scheduler main loop exited.');
  }

  /// Request a clean kernel shutdown.
  void shutdown() {
    _log.info('Kernel shutdown requested.');
    _running = false;
    irq.disableInterrupts();
  }

  // ─── Kernel panic ─────────────────────────────────────────────────────────

  /// Halt the system with a fatal error message.
  ///
  /// In a production build this would disable interrupts, print to UART,
  /// and loop forever. In the Dart host-side tooling it throws an [Error].
  static Never panic(String message, [Object? error, StackTrace? stack]) {
    _log.severe('KERNEL PANIC: $message');
    if (error != null) _log.severe('  cause: $error');
    if (stack != null) _log.severe('  stack:\n$stack');
    // On real hardware: disable IRQs + halt CPU
    throw KernelPanicError(message, error);
  }
}

/// Thrown by [KernelApi.panic] in the Dart host-side simulation.
final class KernelPanicError extends Error {
  final String message;
  final Object? cause;

  KernelPanicError(this.message, [this.cause]);

  @override
  String toString() => 'KernelPanicError: $message${cause != null ? ' (caused by: $cause)' : ''}';
}

// ─────────────────────────────────────────────────────────────────────────────
// BusyWait — spin-wait helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Spin-wait helpers for use in IRQ handlers and early-boot code.
///
/// On bare metal these use the hardware timer counter.
/// In the Dart host simulation they delegate to [Duration] delays.
abstract final class BusyWait {
  /// Spin for approximately [ms] milliseconds.
  static void milliseconds(int ms) {
    // On real hardware: read timer counter and spin until elapsed
    // In simulation: no-op (or use Stopwatch)
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < ms) {
      // spin
    }
  }

  /// Spin for approximately [us] microseconds.
  static void microseconds(int us) {
    final sw = Stopwatch()..start();
    while (sw.elapsedMicroseconds < us) {
      // spin
    }
  }

  /// Spin for approximately [s] seconds.
  static void seconds(int s) => milliseconds(s * 1000);

  /// Spin for approximately [ns] nanoseconds.
  ///
  /// Note: accuracy is limited to the Stopwatch resolution (~1 μs on most hosts).
  static void nanoseconds(int ns) {
    final us = (ns / 1000).ceil();
    microseconds(us);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// KernelTimer — software timer API
// ─────────────────────────────────────────────────────────────────────────────

/// A one-shot or repeating software timer backed by the scheduler.
final class KernelTimer {
  final Duration interval;
  final bool repeating;
  final void Function() callback;

  bool _active = false;
  static final _log = Logger('KernelTimer');

  KernelTimer({
    required this.interval,
    required this.callback,
    this.repeating = false,
  });

  /// Start the timer.
  void start() {
    _active = true;
    _log.fine('KernelTimer started (interval=${interval.inMilliseconds} ms, repeating=$repeating)');
    _schedule();
  }

  /// Cancel the timer.
  void cancel() {
    _active = false;
    _log.fine('KernelTimer cancelled');
  }

  void _schedule() {
    if (!_active) return;

    final sched = TaskScheduler.instance;
    sched.addTask(
      'kernel_timer',
      () {
        if (!_active) return;
        callback();
        if (repeating) _schedule();
      },
      priority: 200, // high priority for timer tasks
    );
  }
}
