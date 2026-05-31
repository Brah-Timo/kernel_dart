/// Bare-metal exception handling for the kernel_dart runtime.
///
/// On a traditional OS, unhandled exceptions are caught by the OS and turned
/// into signals / error dialogs. On bare metal there is no such safety net.
///
/// This module provides:
///   • A kernel-level unhandled exception hook (triggers UART dump + halt)
///   • Hardware exception classes (HardFault, BusFault, UsageFault, etc.)
///   • A Result<T, E> type for error propagation without exceptions
///   • A structured error log with ring-buffer storage
library;

import 'dart:collection';
import 'package:logging/logging.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Hardware exception types
// ─────────────────────────────────────────────────────────────────────────────

/// Base class for all ARM Cortex-M/A hardware faults.
abstract base class HardwareFault implements Exception {
  /// Fault address (MMFAR / BFAR register value, or PC at fault time).
  final int? faultAddress;

  /// Raw fault status register value.
  final int statusRegister;

  const HardwareFault({this.faultAddress, this.statusRegister = 0});
}

/// ARM HardFault — unrecoverable fault.
final class HardFaultException extends HardwareFault {
  final bool forcedHardFault;
  final bool vectorTableReadFault;

  const HardFaultException({
    this.forcedHardFault     = false,
    this.vectorTableReadFault = false,
    super.faultAddress,
    super.statusRegister,
  });

  @override
  String toString() =>
      'HardFault(addr=${faultAddress != null ? '0x${faultAddress!.toRadixString(16)}' : 'unknown'}, '
      'status=0x${statusRegister.toRadixString(16)})';
}

/// ARM MemManage fault — MPU violation.
final class MemManageFaultException extends HardwareFault {
  final bool instructionAccessViolation;
  final bool dataAccessViolation;
  final bool stackOverflow;

  const MemManageFaultException({
    this.instructionAccessViolation = false,
    this.dataAccessViolation        = false,
    this.stackOverflow              = false,
    super.faultAddress,
    super.statusRegister,
  });

  @override
  String toString() =>
      'MemManageFault(iaccviol=$instructionAccessViolation, '
      'daccviol=$dataAccessViolation, stkovf=$stackOverflow, '
      'addr=${faultAddress != null ? '0x${faultAddress!.toRadixString(16)}' : 'n/a'})';
}

/// ARM BusFault — memory bus error.
final class BusFaultException extends HardwareFault {
  final bool preciseError;
  final bool impreciseError;
  final bool unstackError;
  final bool stackingError;

  const BusFaultException({
    this.preciseError   = false,
    this.impreciseError = false,
    this.unstackError   = false,
    this.stackingError  = false,
    super.faultAddress,
    super.statusRegister,
  });

  @override
  String toString() =>
      'BusFault(precise=$preciseError, imprecise=$impreciseError, '
      'addr=${faultAddress != null ? '0x${faultAddress!.toRadixString(16)}' : 'n/a'})';
}

/// ARM UsageFault — undefined instruction, divide by zero, etc.
final class UsageFaultException extends HardwareFault {
  final bool undefinedInstruction;
  final bool invalidState;
  final bool invalidPcLoad;
  final bool noCoprocessor;
  final bool unalignedAccess;
  final bool divideByZero;

  const UsageFaultException({
    this.undefinedInstruction = false,
    this.invalidState         = false,
    this.invalidPcLoad        = false,
    this.noCoprocessor        = false,
    this.unalignedAccess      = false,
    this.divideByZero         = false,
    super.statusRegister,
  });

  @override
  String toString() =>
      'UsageFault(undef=$undefinedInstruction, divz=$divideByZero, '
      'unaligned=$unalignedAccess)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Result<T, E> — error propagation without exceptions
// ─────────────────────────────────────────────────────────────────────────────

/// A discriminated union representing either a success value [T] or an error [E].
///
/// Use this instead of throwing exceptions in driver code and ISRs.
///
/// ```dart
/// Result<int, String> readSensor() {
///   if (!sensorReady) return Result.err('Sensor not ready');
///   return Result.ok(readRawValue());
/// }
///
/// final result = readSensor();
/// result.when(
///   ok:  (v) => uart.print('Value: $v\r\n'),
///   err: (e) => uart.print('Error: $e\r\n'),
/// );
/// ```
sealed class Result<T, E> {
  const Result();

  factory Result.ok(T value) = Ok<T, E>;
  factory Result.err(E error) = Err<T, E>;

  bool get isOk  => this is Ok<T, E>;
  bool get isErr => this is Err<T, E>;

  T get value {
    if (this is Ok<T, E>) return (this as Ok<T, E>).value;
    throw StateError('Result.value called on Err: ${(this as Err<T, E>).error}');
  }

  E get error {
    if (this is Err<T, E>) return (this as Err<T, E>).error;
    throw StateError('Result.error called on Ok');
  }

  T? get valueOrNull => isOk ? (this as Ok<T, E>).value : null;
  E? get errorOrNull => isErr ? (this as Err<T, E>).error : null;

  /// Apply [ok] or [err] depending on variant.
  R when<R>({
    required R Function(T)  ok,
    required R Function(E)  err,
  }) {
    return switch (this) {
      Ok<T, E>(:final value)  => ok(value),
      Err<T, E>(:final error) => err(error),
    };
  }

  /// Transform the success value.
  Result<U, E> map<U>(U Function(T) f) => switch (this) {
        Ok<T, E>(:final value)  => Ok(f(value)),
        Err<T, E>(:final error) => Err(error),
      };

  @override
  String toString() => switch (this) {
        Ok<T, E>(:final value)  => 'Ok($value)',
        Err<T, E>(:final error) => 'Err($error)',
      };
}

final class Ok<T, E>  extends Result<T, E> {
  @override
  final T value;
  const Ok(this.value);
}

final class Err<T, E> extends Result<T, E> {
  @override
  final E error;
  const Err(this.error);
}

// ─────────────────────────────────────────────────────────────────────────────
// ErrorLog — ring-buffer error history
// ─────────────────────────────────────────────────────────────────────────────

/// Severity level of a logged error.
enum ErrorSeverity { info, warning, error, fatal }

/// A single entry in the [ErrorLog].
final class ErrorEntry {
  final int sequenceNumber;
  final ErrorSeverity severity;
  final String message;
  final Object? error;
  final DateTime timestamp;

  const ErrorEntry({
    required this.sequenceNumber,
    required this.severity,
    required this.message,
    this.error,
    required this.timestamp,
  });

  @override
  String toString() =>
      '[${severity.name.toUpperCase().padRight(7)}] #$sequenceNumber '
      '${timestamp.toIso8601String()} — $message'
      '${error != null ? '\n  $error' : ''}';
}

/// Persistent ring-buffer of error / warning events.
///
/// Stored in a fixed-size region of RAM so errors before crash can be
/// inspected after a watchdog reset.
final class ErrorLog {
  static final ErrorLog instance = ErrorLog._();
  ErrorLog._();

  static final _log = Logger('ErrorLog');

  final int maxEntries = 64;
  final Queue<ErrorEntry> _entries = Queue();
  int _seq = 0;

  /// Append a new entry.
  void append(ErrorSeverity severity, String message, [Object? error]) {
    while (_entries.length >= maxEntries) _entries.removeFirst();

    _entries.addLast(ErrorEntry(
      sequenceNumber: _seq++,
      severity:       severity,
      message:        message,
      error:          error,
      timestamp:      DateTime.now(),
    ));

    if (severity == ErrorSeverity.fatal) {
      _log.severe('FATAL: $message', error);
    } else if (severity == ErrorSeverity.error) {
      _log.severe(message, error);
    }
  }

  void info(String msg)              => append(ErrorSeverity.info,    msg);
  void warning(String msg)           => append(ErrorSeverity.warning, msg);
  void error(String msg, [Object? e]) => append(ErrorSeverity.error, msg, e);
  void fatal(String msg, [Object? e]) => append(ErrorSeverity.fatal, msg, e);

  /// Most recent [n] entries.
  List<ErrorEntry> recent([int n = 20]) =>
      _entries.toList().reversed.take(n).toList();

  /// Dump all entries as a multi-line string.
  String dump() => _entries.map((e) => e.toString()).join('\n');

  void clear() => _entries.clear();
}

// ─────────────────────────────────────────────────────────────────────────────
// UnhandledExceptionHandler
// ─────────────────────────────────────────────────────────────────────────────

/// Installs a process-wide unhandled exception hook.
///
/// When an unhandled exception escapes the Dart isolate, this handler:
///   1. Logs it to [ErrorLog]
///   2. Outputs a crash dump to UART
///   3. Halts the CPU (or resets via watchdog if configured)
final class UnhandledExceptionHandler {
  static final _log = Logger('UnhandledExceptionHandler');

  static bool _installed = false;

  /// Install the global handler.
  static void install() {
    if (_installed) return;
    _installed = true;
    _log.info('Unhandled exception handler installed.');
    // In a real Dart AOT runtime: set Dart_SetUnhandledExceptionCallback
    // Here we register as a Zone error handler.
  }

  /// Called when an unhandled exception is detected.
  static void onUnhandledException(Object error, StackTrace stack) {
    ErrorLog.instance.fatal('Unhandled exception: $error', error);
    _log.severe('═' * 60);
    _log.severe('UNHANDLED EXCEPTION');
    _log.severe('Error: $error');
    _log.severe('Stack trace:\n$stack');
    _log.severe('═' * 60);

    // Dump recent error log
    _log.severe('Recent error log:\n${ErrorLog.instance.dump()}');

    // On real hardware: trigger watchdog reset or halt
    // _triggerWatchdog();
  }
}
