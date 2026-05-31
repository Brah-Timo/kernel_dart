/// Interrupt handling subsystem for the kernel_dart microkernel.
///
/// Provides:
///   • An Interrupt Vector Table (IVT) mapping IRQ numbers to handlers
///   • Named IRQ constants for common ARM / x86 interrupts
///   • Interrupt enable / disable / mask helpers
///   • Deferred interrupt processing via a software pending queue
library;

import 'dart:collection';
import 'package:logging/logging.dart';

// ─────────────────────────────────────────────────────────────────────────────
// IRQ numbers — ARM GIC / x86 common mappings
// ─────────────────────────────────────────────────────────────────────────────

/// Well-known ARM GICv2 interrupt numbers.
abstract final class ArmIrq {
  // Software-generated interrupts (SGI)
  static const int sgi0  = 0;
  static const int sgi1  = 1;
  static const int sgi2  = 2;
  static const int sgi3  = 3;

  // Private Peripheral Interrupts (PPI — per core)
  static const int vtimer   = 27; // Virtual timer (Cortex-A)
  static const int ptimer   = 29; // Physical timer
  static const int legacy   = 31; // Legacy FIQ

  // Shared Peripheral Interrupts (SPI — board-specific offset: 32+)
  static const int uart0    = 32 + 33;  // PL011 UART on RasPi
  static const int gpio0    = 32 + 49;
  static const int i2c0     = 32 + 53;
  static const int spi0     = 32 + 54;
  static const int timer0   = 32 + 64;
  static const int usb      = 32 + 9;
  static const int ethernet = 32 + 29;
}

/// Well-known x86 interrupt numbers.
abstract final class X86Irq {
  static const int divideError      = 0;
  static const int singleStep       = 1;
  static const int nmi              = 2;
  static const int breakpoint       = 3;
  static const int overflow         = 4;
  static const int boundRange       = 5;
  static const int invalidOpcode    = 6;
  static const int deviceNotAvail   = 7;
  static const int doubleFault      = 8;
  static const int generalProtect   = 13;
  static const int pageFault        = 14;
  static const int floatingPoint    = 16;
  static const int alignCheck       = 17;
  static const int machineCheck     = 18;
  static const int simdFloat        = 19;

  // PIC IRQ lines (vector offset 32)
  static const int timer            = 32;  // PIT timer
  static const int keyboard         = 33;
  static const int com2             = 35;
  static const int com1             = 36;
  static const int parallelPort     = 39;
  static const int realTimeClock    = 40;
  static const int mouse            = 44;
  static const int coprocessor      = 45;
  static const int primaryAta       = 46;
  static const int secondaryAta     = 47;
}

// ─────────────────────────────────────────────────────────────────────────────
// InterruptContext — snapshot passed to every handler
// ─────────────────────────────────────────────────────────────────────────────

/// CPU register state at the time of the interrupt.
final class InterruptContext {
  /// IRQ / exception number.
  final int irqNumber;

  /// Error code (x86 exceptions only; 0 on ARM).
  final int errorCode;

  /// Simulated program counter (return address).
  final int pc;

  /// Simulated stack pointer.
  final int sp;

  /// Simulated flags / CPSR register value.
  final int flags;

  const InterruptContext({
    required this.irqNumber,
    this.errorCode = 0,
    this.pc        = 0,
    this.sp        = 0,
    this.flags     = 0,
  });

  @override
  String toString() =>
      'InterruptContext(irq=$irqNumber, err=0x${errorCode.toRadixString(16)}, '
      'pc=0x${pc.toRadixString(16)})';
}

// ─────────────────────────────────────────────────────────────────────────────
// InterruptService — handler interface
// ─────────────────────────────────────────────────────────────────────────────

/// Base class for interrupt service routines (ISRs).
abstract base class InterruptService {
  /// Human-readable name (for logging / debug).
  String get name;

  /// Handle the interrupt.
  ///
  /// Must return as quickly as possible (no blocking I/O, no allocations).
  void handle(InterruptContext ctx);

  /// Whether this ISR can be deferred (run later in a bottom-half handler).
  bool get deferrable => false;
}

/// Simple closure-based ISR for quick registration.
final class ClosureInterruptService extends InterruptService {
  @override
  final String name;

  final void Function(InterruptContext) _handler;

  @override
  final bool deferrable;

  ClosureInterruptService(this.name, this._handler, {this.deferrable = false});

  @override
  void handle(InterruptContext ctx) => _handler(ctx);
}

// ─────────────────────────────────────────────────────────────────────────────
// PendingInterrupt — deferred / bottom-half
// ─────────────────────────────────────────────────────────────────────────────

/// An interrupt that has been deferred for later processing.
final class PendingInterrupt {
  final InterruptService service;
  final InterruptContext context;
  final DateTime queuedAt;

  PendingInterrupt({
    required this.service,
    required this.context,
    required this.queuedAt,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// InterruptHandler — central dispatcher
// ─────────────────────────────────────────────────────────────────────────────

/// Central interrupt dispatcher (singleton).
///
/// ```dart
/// final irq = InterruptHandler.instance;
///
/// // Register a timer handler
/// irq.register(ArmIrq.ptimer, ClosureInterruptService(
///   'timer', (ctx) => scheduler.tick(),
/// ));
///
/// // Called from Assembly when an IRQ fires
/// irq.dispatch(ArmIrq.ptimer);
/// ```
final class InterruptHandler {
  // ─── Singleton ─────────────────────────────────────────────────────────────

  static final InterruptHandler instance = InterruptHandler._();
  InterruptHandler._();

  // ─── State ─────────────────────────────────────────────────────────────────

  final Map<int, InterruptService> _ivt    = {};
  final Queue<PendingInterrupt>    _pending = Queue();

  bool _interruptsEnabled = false;
  int  _totalDispatched   = 0;
  int  _totalDeferred     = 0;
  int  _totalUnhandled    = 0;

  static final _log = Logger('InterruptHandler');

  // ─── Registration ─────────────────────────────────────────────────────────

  /// Register [service] as the handler for [irqNumber].
  ///
  /// Replaces any previously registered handler for that IRQ.
  void register(int irqNumber, InterruptService service) {
    _ivt[irqNumber] = service;
    _log.info('IRQ $irqNumber → "${service.name}"');
  }

  /// Register a closure as the handler for [irqNumber].
  void registerHandler(
    int irqNumber,
    String name,
    void Function(InterruptContext) handler, {
    bool deferrable = false,
  }) {
    register(
      irqNumber,
      ClosureInterruptService(name, handler, deferrable: deferrable),
    );
  }

  /// Unregister the handler for [irqNumber].
  void unregister(int irqNumber) {
    _ivt.remove(irqNumber);
    _log.info('IRQ $irqNumber unregistered');
  }

  // ─── Dispatch ─────────────────────────────────────────────────────────────

  /// Dispatch an interrupt (called from Assembly / ISR context).
  ///
  /// If the handler is [InterruptService.deferrable], it is placed in the
  /// pending queue instead of being called immediately.
  void dispatch(int irqNumber, {int errorCode = 0, int pc = 0, int sp = 0}) {
    _totalDispatched++;

    final ctx = InterruptContext(
      irqNumber:  irqNumber,
      errorCode:  errorCode,
      pc:         pc,
      sp:         sp,
    );

    final service = _ivt[irqNumber];

    if (service == null) {
      _totalUnhandled++;
      _log.warning('Unhandled IRQ $irqNumber (total: $_totalUnhandled)');
      _defaultHandler(ctx);
      return;
    }

    if (service.deferrable) {
      _defer(service, ctx);
    } else {
      _invoke(service, ctx);
    }
  }

  /// Process all pending (deferred) interrupts.
  ///
  /// Called from the kernel's main loop or from the scheduler idle task.
  void processPending() {
    while (_pending.isNotEmpty) {
      final item = _pending.removeFirst();
      _invoke(item.service, item.context);
    }
  }

  // ─── Interrupt masking ────────────────────────────────────────────────────

  /// Enable global interrupt delivery.
  void enableInterrupts() {
    _interruptsEnabled = true;
    _log.fine('Interrupts ENABLED');
    // On real hardware: cpsie i  (ARM) / sti  (x86)
  }

  /// Disable global interrupt delivery (critical section).
  void disableInterrupts() {
    _interruptsEnabled = false;
    _log.fine('Interrupts DISABLED');
    // On real hardware: cpsid i  (ARM) / cli  (x86)
  }

  /// Execute [fn] with interrupts disabled (atomic critical section).
  T criticalSection<T>(T Function() fn) {
    disableInterrupts();
    try {
      return fn();
    } finally {
      enableInterrupts();
    }
  }

  /// Mask (silence) a specific IRQ line.
  void maskIrq(int irqNumber) {
    _log.fine('mask IRQ $irqNumber');
    // On real hardware: write to GIC Interrupt Clear-Enable register
  }

  /// Unmask (re-enable) a specific IRQ line.
  void unmaskIrq(int irqNumber) {
    _log.fine('unmask IRQ $irqNumber');
    // On real hardware: write to GIC Interrupt Set-Enable register
  }

  // ─── Statistics ───────────────────────────────────────────────────────────

  InterruptStats getStats() => InterruptStats(
        registeredHandlers: _ivt.length,
        totalDispatched:    _totalDispatched,
        totalDeferred:      _totalDeferred,
        totalUnhandled:     _totalUnhandled,
        pendingCount:       _pending.length,
        interruptsEnabled:  _interruptsEnabled,
      );

  // ─── Internal helpers ─────────────────────────────────────────────────────

  void _invoke(InterruptService service, InterruptContext ctx) {
    _log.fine('IRQ ${ctx.irqNumber} → "${service.name}"');
    try {
      service.handle(ctx);
    } on Exception catch (e, st) {
      _log.severe('IRQ ${ctx.irqNumber} handler crashed: $e\n$st');
    }
  }

  void _defer(InterruptService service, InterruptContext ctx) {
    _totalDeferred++;
    _pending.addLast(PendingInterrupt(
      service:  service,
      context:  ctx,
      queuedAt: DateTime.now(),
    ));
    _log.fine('IRQ ${ctx.irqNumber} deferred (${_pending.length} pending)');
  }

  void _defaultHandler(InterruptContext ctx) {
    // Check for fatal exceptions (page fault, general protection, etc.)
    if (ctx.irqNumber == X86Irq.pageFault ||
        ctx.irqNumber == X86Irq.doubleFault ||
        ctx.irqNumber == X86Irq.generalProtect) {
      _log.severe('FATAL EXCEPTION: IRQ ${ctx.irqNumber}, error=0x${ctx.errorCode.toRadixString(16)}');
      // In a real kernel: halt the system (cli + hlt)
    }
  }
}

/// Statistics snapshot for [InterruptHandler].
final class InterruptStats {
  final int registeredHandlers;
  final int totalDispatched;
  final int totalDeferred;
  final int totalUnhandled;
  final int pendingCount;
  final bool interruptsEnabled;

  const InterruptStats({
    required this.registeredHandlers,
    required this.totalDispatched,
    required this.totalDeferred,
    required this.totalUnhandled,
    required this.pendingCount,
    required this.interruptsEnabled,
  });

  @override
  String toString() =>
      'InterruptStats(handlers=$registeredHandlers, '
      'dispatched=$totalDispatched, deferred=$totalDeferred, '
      'unhandled=$totalUnhandled, pending=$pendingCount)';
}
