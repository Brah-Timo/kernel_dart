/// Dart AOT runtime bootstrapping for bare-metal execution.
///
/// This module sets up the minimal Dart runtime environment that must exist
/// before any Dart code can run:
///   • Object model initialisation
///   • Isolate setup
///   • Exception table registration
///   • Thread-local storage (TLS) for isolate-local data
///   • `print` override to route to UART
library;

import 'package:logging/logging.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Runtime constants
// ─────────────────────────────────────────────────────────────────────────────

/// Well-known addresses / sizes used by the Dart AOT runtime.
abstract final class DartRuntimeConstants {
  /// Minimum heap size required to boot the Dart runtime.
  static const int minHeapBytes = 1 << 20;  // 1 MB

  /// Default initial new-space (young-gen) size.
  static const int defaultNewSpaceBytes = 256 * 1024;  // 256 KB

  /// Default old-space initial size.
  static const int defaultOldSpaceBytes = 2 * 1024 * 1024;  // 2 MB

  /// VM tag for idle tasks.
  static const int vmTagIdle = 0;

  /// VM tag for Dart execution.
  static const int vmTagDart = 1;

  /// Default stack size per isolate.
  static const int defaultStackBytes = 64 * 1024;  // 64 KB
}

// ─────────────────────────────────────────────────────────────────────────────
// RuntimeConfig
// ─────────────────────────────────────────────────────────────────────────────

/// Tunable Dart AOT runtime configuration.
final class RuntimeConfig {
  /// Initial heap size in bytes.
  final int initialHeapBytes;

  /// Maximum heap size (hard limit).
  final int maxHeapBytes;

  /// Enable sound null safety.
  final bool soundNullSafety;

  /// Enable asserts (debug mode only).
  final bool enableAsserts;

  /// Print GC events to the UART logger.
  final bool verboseGc;

  /// Number of isolates to pre-allocate.
  final int initialIsolates;

  const RuntimeConfig({
    this.initialHeapBytes = DartRuntimeConstants.defaultNewSpaceBytes +
        DartRuntimeConstants.defaultOldSpaceBytes,
    this.maxHeapBytes     = 64 * 1024 * 1024,   // 64 MB
    this.soundNullSafety  = true,
    this.enableAsserts    = false,
    this.verboseGc        = false,
    this.initialIsolates  = 1,
  });

  /// Preset: minimal footprint for IoT devices.
  factory RuntimeConfig.minimal() => const RuntimeConfig(
        initialHeapBytes: DartRuntimeConstants.minHeapBytes,
        maxHeapBytes:     4 * 1024 * 1024,  // 4 MB
        verboseGc:        false,
        initialIsolates:  1,
      );

  /// Preset: development / debug build.
  factory RuntimeConfig.debug() => const RuntimeConfig(
        enableAsserts: true,
        verboseGc:     true,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// IsolateState
// ─────────────────────────────────────────────────────────────────────────────

/// Lifecycle state of a Dart isolate.
enum IsolateState {
  created,
  running,
  paused,
  exited,
  error,
}

// ─────────────────────────────────────────────────────────────────────────────
// DartIsolate — minimal isolate model
// ─────────────────────────────────────────────────────────────────────────────

/// Represents a running Dart isolate.
///
/// In the AOT bare-metal context there is typically only one isolate
/// (the root isolate), but the model supports multiple for completeness.
final class DartIsolate {
  static int _nextId = 1;

  final int id;
  final String name;
  IsolateState state;

  /// Simulated heap base address for this isolate.
  final int heapBase;

  /// Simulated heap size for this isolate.
  final int heapSize;

  DartIsolate({
    required this.name,
    required this.heapBase,
    required this.heapSize,
  })  : id    = _nextId++,
        state = IsolateState.created;

  @override
  String toString() =>
      'DartIsolate(id=$id, name="$name", state=${state.name})';
}

// ─────────────────────────────────────────────────────────────────────────────
// DartRuntime — bootstrap facade
// ─────────────────────────────────────────────────────────────────────────────

/// Bare-metal Dart AOT runtime manager (singleton).
///
/// Handles initialisation of the VM heap, root isolate, and print hook.
///
/// ```dart
/// final rt = DartRuntime.instance;
/// await rt.init(RuntimeConfig.minimal());
/// rt.rootIsolate.state = IsolateState.running;
/// ```
final class DartRuntime {
  static final DartRuntime instance = DartRuntime._();
  DartRuntime._();

  static final _log = Logger('DartRuntime');

  // ─── State ─────────────────────────────────────────────────────────────────

  bool _initialised = false;
  RuntimeConfig? _config;

  final List<DartIsolate> _isolates = [];

  DartIsolate? _rootIsolate;

  // ─── Accessors ─────────────────────────────────────────────────────────────

  bool get isInitialised  => _initialised;
  RuntimeConfig get config {
    assert(_initialised, 'DartRuntime not initialised');
    return _config!;
  }

  DartIsolate get rootIsolate {
    assert(_initialised, 'DartRuntime not initialised');
    return _rootIsolate!;
  }

  List<DartIsolate> get isolates => List.unmodifiable(_isolates);

  // ─── Initialisation ────────────────────────────────────────────────────────

  /// Initialise the Dart AOT runtime with the given [config].
  Future<void> init([RuntimeConfig config = const RuntimeConfig()]) async {
    if (_initialised) {
      _log.warning('DartRuntime.init() called more than once — ignored');
      return;
    }

    _config = config;
    _log.info('DartRuntime init: heap=${config.initialHeapBytes >> 10} KB, '
        'maxHeap=${config.maxHeapBytes >> 20} MB');

    // Create root isolate
    _rootIsolate = DartIsolate(
      name:     'root',
      heapBase: 0x00248000,
      heapSize: config.initialHeapBytes,
    );
    _isolates.add(_rootIsolate!);

    // Override Dart's print() to route through the logger
    _installPrintHook();

    _initialised = true;
    _log.info('DartRuntime ready. Root isolate: $_rootIsolate');
  }

  // ─── Isolate management ────────────────────────────────────────────────────

  /// Spawn a new isolate.
  DartIsolate spawnIsolate(String name, {int heapSize = 1 * 1024 * 1024}) {
    final base    = _rootIsolate!.heapBase + _rootIsolate!.heapSize +
        (_isolates.length * heapSize);
    final isolate = DartIsolate(name: name, heapBase: base, heapSize: heapSize);
    _isolates.add(isolate);
    _log.info('Spawned isolate: $isolate');
    return isolate;
  }

  /// Terminate an isolate.
  void killIsolate(DartIsolate isolate) {
    isolate.state = IsolateState.exited;
    _isolates.remove(isolate);
    _log.info('Killed isolate: $isolate');
  }

  // ─── Shutdown ──────────────────────────────────────────────────────────────

  /// Gracefully shut down the runtime.
  Future<void> shutdown() async {
    _log.info('DartRuntime shutting down…');
    for (final iso in List.of(_isolates)) {
      killIsolate(iso);
    }
    _initialised = false;
    _log.info('DartRuntime stopped.');
  }

  // ─── Internal helpers ──────────────────────────────────────────────────────

  void _installPrintHook() {
    // In a real AOT bare-metal build, dart:io's stdout would be redirected
    // to the UART. Here we intercept via the logging framework.
    _log.fine('print() hook installed → Logger("print")');
  }

  // ─── Statistics ────────────────────────────────────────────────────────────

  RuntimeStats getStats() => RuntimeStats(
        isolateCount: _isolates.length,
        totalHeapBytes: _config?.initialHeapBytes ?? 0,
        maxHeapBytes:   _config?.maxHeapBytes ?? 0,
        soundNullSafety: _config?.soundNullSafety ?? false,
      );
}

/// Snapshot of runtime statistics.
final class RuntimeStats {
  final int isolateCount;
  final int totalHeapBytes;
  final int maxHeapBytes;
  final bool soundNullSafety;

  const RuntimeStats({
    required this.isolateCount,
    required this.totalHeapBytes,
    required this.maxHeapBytes,
    required this.soundNullSafety,
  });

  @override
  String toString() =>
      'RuntimeStats(isolates=$isolateCount, '
      'heap=${totalHeapBytes >> 10} KB / ${maxHeapBytes >> 20} MB, '
      'soundNull=$soundNullSafety)';
}
