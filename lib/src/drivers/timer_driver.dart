/// Hardware timer driver (ARM SP804 / BCM2835 system timer).
///
/// Provides:
///   • One-shot and periodic hardware timer configuration
///   • Timer tick counter (monotonic clock)
///   • Busy-wait delays (polling-based)
///   • Software timer list (linked to hardware IRQ)
// ignore_for_file: unused_field
library;

import 'package:logging/logging.dart';

import '../kernel/device_drivers.dart';
import '../runtime/ffi_bridge.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SP804 register offsets (Dual Timer Module)
// ─────────────────────────────────────────────────────────────────────────────

abstract final class _SP804 {
  // Timer 1 (base + 0x000)
  static const int timer1Load    = 0x000;
  static const int timer1Value   = 0x004;
  static const int timer1Control = 0x008;
  static const int timer1IntClr  = 0x00C;
  static const int timer1Ris     = 0x010;
  static const int timer1Mis     = 0x014;
  static const int timer1BgLoad  = 0x018;

  // Timer 2 (base + 0x020)
  static const int timer2Load    = 0x020;
  static const int timer2Value   = 0x024;
  static const int timer2Control = 0x028;
  static const int timer2IntClr  = 0x02C;

  // Control register bits
  static const int ctrlOneShot   = 1 << 0;  // 0 = wrapping, 1 = one-shot
  static const int ctrl32bit     = 1 << 1;  // 0 = 16-bit, 1 = 32-bit
  static const int ctrlPre1      = 0 << 2;  // Prescale /1
  static const int ctrlPre16     = 1 << 2;  // Prescale /16
  static const int ctrlPre256    = 2 << 2;  // Prescale /256
  static const int ctrlIntEnable = 1 << 5;  // Interrupt enable
  static const int ctrlPeriodic  = 1 << 6;  // Periodic mode
  static const int ctrlEnable    = 1 << 7;  // Timer enable
}

// ─────────────────────────────────────────────────────────────────────────────
// BCM2835 System Timer registers (Raspberry Pi)
// ─────────────────────────────────────────────────────────────────────────────

abstract final class _BCM2835Timer {
  static const int cs  = 0x00; // Control/Status
  static const int clo = 0x04; // Counter Low 32 bits
  static const int chi = 0x08; // Counter High 32 bits
  static const int c0  = 0x0C; // Compare 0
  static const int c1  = 0x10; // Compare 1
  static const int c2  = 0x14; // Compare 2
  static const int c3  = 0x18; // Compare 3
}

// ─────────────────────────────────────────────────────────────────────────────
// Software timer
// ─────────────────────────────────────────────────────────────────────────────

/// A software timer backed by a hardware timer IRQ.
final class SoftwareTimer {
  static int _nextId = 1;

  final int id;
  final String name;
  final Duration interval;
  final bool repeating;
  final void Function() callback;

  int _targetTick;
  bool active;

  SoftwareTimer({
    required this.name,
    required this.interval,
    required this.callback,
    this.repeating = false,
    required int initialTick,
  })  : id          = _nextId++,
        _targetTick = initialTick,
        active      = true;

  int get targetTick => _targetTick;

  void reschedule(int currentTick) {
    _targetTick = currentTick + interval.inMicroseconds;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TimerDriver
// ─────────────────────────────────────────────────────────────────────────────

/// Hardware timer driver with software timer support.
///
/// ```dart
/// final timer = TimerDriver(baseAddress: 0x3F003000);
/// await timer.init();
///
/// timer.scheduleTimer('heartbeat', Duration(seconds: 1), () {
///   uart.print('tick\r\n');
/// }, repeating: true);
/// ```
final class TimerDriver extends DeviceDriver {
  final int _base;

  /// Timer input clock frequency in Hz.
  final int clockHz;

  /// Monotonic tick counter (incremented per hardware IRQ).
  int _ticks = 0;

  /// Elapsed microseconds since boot.
  int _elapsedUs = 0;

  final List<SoftwareTimer> _softwareTimers = [];

  static final _log = Logger('TimerDriver');

  TimerDriver({
    required int baseAddress,
    this.clockHz = 1000000, // 1 MHz (BCM2835 system timer)
  }) : _base = baseAddress;

  @override
  DeviceInfo get info => DeviceInfo(
        name:        'timer0',
        description: 'ARM SP804 / BCM2835 System Timer',
        type:        DeviceType.timer,
        baseAddress: _base,
        irqNumber:   64,
      );

  // ─── DeviceDriver lifecycle ───────────────────────────────────────────────

  @override
  Future<void> init() async {
    // Configure Timer 1: 32-bit, periodic, IRQ enabled, 1 ms period
    final loadValue = clockHz ~/ 1000 - 1; // 1 ms at clockHz

    MMIO.write32(_base + _SP804.timer1Control, 0);     // disable first
    MMIO.write32(_base + _SP804.timer1Load, loadValue);
    MMIO.write32(
      _base + _SP804.timer1Control,
      _SP804.ctrl32bit    |
      _SP804.ctrlPeriodic |
      _SP804.ctrlIntEnable |
      _SP804.ctrlEnable,
    );

    _log.info('Timer0 init: base=0x${_base.toRadixString(16)}, '
        'load=$loadValue (1 ms), clock=$clockHz Hz');
  }

  @override
  Future<void> cleanup() async {
    MMIO.write32(_base + _SP804.timer1Control, 0);
    _softwareTimers.clear();
    status = DeviceStatus.removed;
  }

  // ─── Monotonic clock ──────────────────────────────────────────────────────

  /// Monotonic tick count since boot (1 tick = timer period, default 1 ms).
  int get ticks => _ticks;

  /// Elapsed time since boot in milliseconds.
  int get elapsedMs => _ticks; // 1 tick = 1 ms

  /// Elapsed time since boot in microseconds.
  int get elapsedUs => _elapsedUs;

  /// Read the 64-bit BCM2835 free-running counter (1 MHz).
  int readCounter64() {
    final hi1 = MMIO.read32(_base + _BCM2835Timer.chi);
    final lo  = MMIO.read32(_base + _BCM2835Timer.clo);
    final hi2 = MMIO.read32(_base + _BCM2835Timer.chi);
    // If hi changed, re-read lo
    return (hi1 == hi2)
        ? (hi1 << 32) | lo
        : ((hi2 << 32) | MMIO.read32(_base + _BCM2835Timer.clo));
  }

  // ─── Delays ───────────────────────────────────────────────────────────────

  /// Busy-wait for [ms] milliseconds.
  void delayMs(int ms) {
    final target = _ticks + ms;
    while (_ticks < target) CPU.nop();
  }

  /// Busy-wait for [us] microseconds using the hardware counter.
  void delayUs(int us) {
    final start  = readCounter64();
    final target = start + us;
    while (readCounter64() < target) CPU.nop();
  }

  // ─── Hardware timer control ───────────────────────────────────────────────

  /// Configure timer 1 for a one-shot interrupt after [duration].
  void oneShot(Duration duration) {
    final loadValue = (duration.inMicroseconds * clockHz) ~/ 1000000;

    MMIO.write32(_base + _SP804.timer1Control, 0);
    MMIO.write32(_base + _SP804.timer1Load, loadValue);
    MMIO.write32(
      _base + _SP804.timer1Control,
      _SP804.ctrl32bit   |
      _SP804.ctrlOneShot |
      _SP804.ctrlIntEnable |
      _SP804.ctrlEnable,
    );
  }

  /// Stop timer 1.
  void stop() => MMIO.write32(_base + _SP804.timer1Control, 0);

  // ─── Software timers ─────────────────────────────────────────────────────

  /// Schedule a software timer.
  SoftwareTimer scheduleTimer(
    String name,
    Duration interval,
    void Function() callback, {
    bool repeating = false,
  }) {
    final t = SoftwareTimer(
      name:        name,
      interval:    interval,
      callback:    callback,
      repeating:   repeating,
      initialTick: _ticks + interval.inMilliseconds,
    );
    _softwareTimers.add(t);
    _log.info('Software timer "$name" scheduled (interval=${interval.inMs} ms, repeating=$repeating)');
    return t;
  }

  /// Cancel a software timer.
  void cancelTimer(SoftwareTimer t) {
    t.active = false;
    _softwareTimers.remove(t);
  }

  // ─── IRQ handler (called by interrupt dispatcher) ─────────────────────────

  @override
  void handleIrq(int irqNumber) {
    // Clear the hardware interrupt
    MMIO.write32(_base + _SP804.timer1IntClr, 1);

    _ticks++;
    _elapsedUs += 1000; // 1 ms per tick

    // Fire due software timers
    final due = <SoftwareTimer>[];
    for (final t in _softwareTimers) {
      if (t.active && t.targetTick <= _ticks) due.add(t);
    }

    for (final t in due) {
      t.callback();
      if (t.repeating) {
        t.reschedule(_ticks);
      } else {
        t.active = false;
        _softwareTimers.remove(t);
      }
    }
  }

  // ─── Statistics ──────────────────────────────────────────────────────────

  TimerStats getStats() => TimerStats(
        ticks:           _ticks,
        elapsedMs:       elapsedMs,
        softwareTimers:  _softwareTimers.length,
        clockHz:         clockHz,
      );
}

/// Snapshot of timer statistics.
final class TimerStats {
  final int ticks;
  final int elapsedMs;
  final int softwareTimers;
  final int clockHz;

  const TimerStats({
    required this.ticks,
    required this.elapsedMs,
    required this.softwareTimers,
    required this.clockHz,
  });

  @override
  String toString() =>
      'TimerStats(ticks=$ticks, elapsed=${elapsedMs}ms, '
      'softwareTimers=$softwareTimers, clock=${clockHz ~/ 1000} kHz)';
}

extension on Duration {
  int get inMs => inMilliseconds;
}
