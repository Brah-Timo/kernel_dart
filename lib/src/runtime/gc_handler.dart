/// Garbage Collector coordination layer for the kernel_dart runtime.
///
/// The Dart AOT runtime includes its own GC, but on bare-metal we need
/// additional hooks to:
///   • Pause hardware interrupts during GC stop-the-world phases
///   • Report GC events to UART for debugging
///   • Implement a conservative GC for the kernel's own C-style heap
///   • Provide GC tuning helpers (new-space / old-space ratios)
library;

import 'dart:math' as math;
import 'package:logging/logging.dart';

// ─────────────────────────────────────────────────────────────────────────────
// GcPhase
// ─────────────────────────────────────────────────────────────────────────────

/// Phases of a garbage collection cycle.
enum GcPhase {
  idle,           // No GC in progress
  marking,        // Mark live objects (stop-the-world)
  sweeping,       // Reclaim dead objects
  compacting,     // Compact heap (optional)
  finalizing,     // Run finalizers for dead objects
}

// ─────────────────────────────────────────────────────────────────────────────
// GcEvent
// ─────────────────────────────────────────────────────────────────────────────

/// Describes a single completed GC cycle.
final class GcEvent {
  final GcType type;
  final int collectedBytes;
  final int heapBeforeBytes;
  final int heapAfterBytes;
  final Duration duration;
  final DateTime timestamp;

  const GcEvent({
    required this.type,
    required this.collectedBytes,
    required this.heapBeforeBytes,
    required this.heapAfterBytes,
    required this.duration,
    required this.timestamp,
  });

  @override
  String toString() =>
      'GcEvent(${type.name}, -${collectedBytes >> 10} KB, '
      '${heapBeforeBytes >> 10}→${heapAfterBytes >> 10} KB, '
      '${duration.inMicroseconds} μs)';
}

/// Type of a GC cycle.
enum GcType {
  /// Minor GC — collects the young / new generation only.
  minor,

  /// Major GC — full heap collection.
  major,

  /// Concurrent GC (incremental marking, no full STW).
  concurrent,
}

// ─────────────────────────────────────────────────────────────────────────────
// GcStats
// ─────────────────────────────────────────────────────────────────────────────

/// Cumulative GC statistics since boot.
final class GcStats {
  final int minorCollections;
  final int majorCollections;
  final int totalCollectedBytes;
  final Duration totalGcTime;
  final Duration longestPause;
  final int currentHeapBytes;
  final int maxHeapBytes;

  const GcStats({
    required this.minorCollections,
    required this.majorCollections,
    required this.totalCollectedBytes,
    required this.totalGcTime,
    required this.longestPause,
    required this.currentHeapBytes,
    required this.maxHeapBytes,
  });

  double get gcOverheadPercent {
    // GC time as a fraction of total uptime (rough estimate)
    final uptime = DateTime.now().millisecondsSinceEpoch;
    if (uptime == 0) return 0;
    return (totalGcTime.inMilliseconds / uptime) * 100;
  }

  @override
  String toString() =>
      'GcStats(\n'
      '  minor: $minorCollections, major: $majorCollections\n'
      '  collected: ${totalCollectedBytes >> 10} KB total\n'
      '  gc time: ${totalGcTime.inMilliseconds} ms '
      '(${gcOverheadPercent.toStringAsFixed(2)} % overhead)\n'
      '  longest pause: ${longestPause.inMicroseconds} μs\n'
      '  heap: ${currentHeapBytes >> 10} / ${maxHeapBytes >> 10} KB\n'
      ')';
}

// ─────────────────────────────────────────────────────────────────────────────
// GcPolicy
// ─────────────────────────────────────────────────────────────────────────────

/// Configures when and how the GC fires.
final class GcPolicy {
  /// Fraction of heap that must be used before triggering a minor GC.
  final double minorGcThreshold;

  /// Fraction of heap that must be used before triggering a major GC.
  final double majorGcThreshold;

  /// Target pause time for incremental / concurrent GC.
  final Duration targetPause;

  /// Maximum allocation rate (bytes/ms) before forcing a GC.
  final int maxAllocRateBytesPerMs;

  const GcPolicy({
    this.minorGcThreshold        = 0.75,
    this.majorGcThreshold        = 0.90,
    this.targetPause             = const Duration(milliseconds: 5),
    this.maxAllocRateBytesPerMs  = 64 * 1024,  // 64 KB/ms
  });

  factory GcPolicy.aggressive() => const GcPolicy(
        minorGcThreshold: 0.50,
        majorGcThreshold: 0.75,
        targetPause:      Duration(milliseconds: 2),
      );

  factory GcPolicy.conservative() => const GcPolicy(
        minorGcThreshold: 0.85,
        majorGcThreshold: 0.95,
        targetPause:      Duration(milliseconds: 10),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// GcHandler — central GC coordinator
// ─────────────────────────────────────────────────────────────────────────────

/// Coordinates garbage collection for the bare-metal Dart runtime.
///
/// Listens for allocation pressure events from [MemoryManager] and triggers
/// GC cycles according to [GcPolicy]. Also provides hooks for IRQ pause/resume.
final class GcHandler {
  static final GcHandler instance = GcHandler._();
  GcHandler._();

  static final _log = Logger('GcHandler');

  // ─── State ─────────────────────────────────────────────────────────────────

  GcPhase _phase         = GcPhase.idle;
  GcPolicy _policy       = const GcPolicy();

  int _minorCount        = 0;
  int _majorCount        = 0;
  int _totalCollected    = 0;
  Duration _totalGcTime  = Duration.zero;
  Duration _longestPause = Duration.zero;

  int _currentHeap = 0;
  int _maxHeap     = 64 * 1024 * 1024;

  final List<GcEvent>  _history   = [];
  final List<void Function(GcEvent)> _listeners = [];

  // ─── Configuration ─────────────────────────────────────────────────────────

  /// Update the GC policy at runtime.
  void setPolicy(GcPolicy policy) {
    _policy = policy;
    _log.info('GC policy updated: minorAt=${(policy.minorGcThreshold * 100).toStringAsFixed(0)}%, '
        'majorAt=${(policy.majorGcThreshold * 100).toStringAsFixed(0)}%');
  }

  // ─── Trigger GC ────────────────────────────────────────────────────────────

  /// Suggest a minor GC (collect young generation only).
  ///
  /// Returns bytes collected.
  int suggestMinorGc() {
    if (_phase != GcPhase.idle) return 0;
    return _runGc(GcType.minor);
  }

  /// Force a full major GC.
  ///
  /// Returns bytes collected.
  int forceFullGc() => _runGc(GcType.major);

  /// Called by the allocator on every allocation.
  ///
  /// Triggers a GC cycle if allocation pressure is high.
  void notifyAllocation(int bytes) {
    _currentHeap += bytes;

    final ratio = _currentHeap / _maxHeap;

    if (ratio >= _policy.majorGcThreshold) {
      _log.info('GC trigger: major (heap=${(_currentHeap >> 10)} KB = ${(ratio * 100).toStringAsFixed(1)}%)');
      _runGc(GcType.major);
    } else if (ratio >= _policy.minorGcThreshold) {
      _log.fine('GC trigger: minor (heap=${(_currentHeap >> 10)} KB)');
      _runGc(GcType.minor);
    }
  }

  /// Called by the allocator when memory is freed.
  void notifyFree(int bytes) {
    _currentHeap = math.max(0, _currentHeap - bytes);
  }

  // ─── Phase query ───────────────────────────────────────────────────────────

  GcPhase get currentPhase => _phase;
  bool get isRunning => _phase != GcPhase.idle;

  // ─── Event listeners ───────────────────────────────────────────────────────

  /// Subscribe to GC completion events.
  void addListener(void Function(GcEvent) listener) => _listeners.add(listener);

  /// Unsubscribe.
  void removeListener(void Function(GcEvent) listener) => _listeners.remove(listener);

  // ─── Statistics ────────────────────────────────────────────────────────────

  GcStats getStats() => GcStats(
        minorCollections:    _minorCount,
        majorCollections:    _majorCount,
        totalCollectedBytes: _totalCollected,
        totalGcTime:         _totalGcTime,
        longestPause:        _longestPause,
        currentHeapBytes:    _currentHeap,
        maxHeapBytes:        _maxHeap,
      );

  /// Last [n] GC events.
  List<GcEvent> getHistory([int n = 10]) =>
      _history.reversed.take(n).toList();

  // ─── Internal GC cycle ────────────────────────────────────────────────────

  int _runGc(GcType type) {
    final sw         = Stopwatch()..start();
    final heapBefore = _currentHeap;

    // ── Mark phase ──────────────────────────────────────────────────────────
    _phase = GcPhase.marking;
    _log.fine('GC ${type.name}: marking…');
    // (In a real runtime, pause all isolates and scan the heap graph)

    // ── Sweep phase ─────────────────────────────────────────────────────────
    _phase = GcPhase.sweeping;
    final collected = _simulateSweep(type);
    _currentHeap    = math.max(0, _currentHeap - collected);

    // ── Compact (major GC only) ──────────────────────────────────────────────
    if (type == GcType.major) {
      _phase = GcPhase.compacting;
      _log.fine('GC major: compacting…');
    }

    // ── Finalizing ──────────────────────────────────────────────────────────
    _phase = GcPhase.finalizing;

    // ── Done ────────────────────────────────────────────────────────────────
    _phase = GcPhase.idle;
    sw.stop();

    final event = GcEvent(
      type:             type,
      collectedBytes:   collected,
      heapBeforeBytes:  heapBefore,
      heapAfterBytes:   _currentHeap,
      duration:         sw.elapsed,
      timestamp:        DateTime.now(),
    );

    _history.add(event);
    _notifyListeners(event);

    // Update stats
    if (type == GcType.minor) _minorCount++; else _majorCount++;
    _totalCollected  += collected;
    _totalGcTime     += sw.elapsed;
    if (sw.elapsed > _longestPause) _longestPause = sw.elapsed;

    _log.info('GC done: $event');
    return collected;
  }

  int _simulateSweep(GcType type) {
    // Simulate collecting 30% (minor) or 60% (major) of current heap
    final ratio = type == GcType.minor ? 0.30 : 0.60;
    return (_currentHeap * ratio).round();
  }

  void _notifyListeners(GcEvent event) {
    for (final l in _listeners) l(event);
  }
}
