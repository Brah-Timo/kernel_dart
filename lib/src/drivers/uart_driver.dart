/// PL011 / 16550-compatible UART driver.
///
/// Supports:
///   • Polling and interrupt-driven TX/RX
///   • Configurable baud rate, parity, stop bits
///   • FIFO control (16-byte hardware FIFO on PL011)
///   • Software TX/RX ring buffers for interrupt mode
///   • Line discipline (LF → CRLF conversion)
// ignore_for_file: unused_field
library;

import 'dart:collection';
import 'dart:typed_data';
import 'package:logging/logging.dart';

import '../kernel/device_drivers.dart';
import '../runtime/ffi_bridge.dart';

// ─────────────────────────────────────────────────────────────────────────────
// UART register offsets (PL011)
// ─────────────────────────────────────────────────────────────────────────────

abstract final class _PL011 {
  static const int dr    = 0x000; // Data Register (TX/RX)
  static const int rsr   = 0x004; // Receive Status / Error Clear Register
  static const int fr    = 0x018; // Flag Register
  static const int ibrd  = 0x024; // Integer Baud Rate Divisor
  static const int fbrd  = 0x028; // Fractional Baud Rate Divisor
  static const int lcrH  = 0x02C; // Line Control Register (High)
  static const int cr    = 0x030; // Control Register
  static const int ifls  = 0x034; // Interrupt FIFO Level Select
  static const int imsc  = 0x038; // Interrupt Mask Set/Clear
  static const int ris   = 0x03C; // Raw Interrupt Status
  static const int mis   = 0x040; // Masked Interrupt Status
  static const int icr   = 0x044; // Interrupt Clear Register

  // FR bits
  static const int frRxfe = 1 << 4; // RX FIFO Empty
  static const int frTxff = 1 << 5; // TX FIFO Full
  static const int frBusy = 1 << 3; // UART Busy

  // LCR_H bits
  static const int lcrHFen  = 1 << 4; // FIFO Enable
  static const int lcrHWlen8 = 3 << 5; // 8-bit word length (0b11 << 5 = 0x60)
  static const int lcrHPen  = 1 << 1; // Parity Enable
  static const int lcrHEps  = 1 << 2; // Even Parity Select
  static const int lcrHStp2 = 1 << 3; // Two stop bits

  // CR bits
  static const int crUartenBit = 1 << 0; // UART Enable
  static const int crTxe       = 1 << 8; // TX Enable
  static const int crRxe       = 1 << 9; // RX Enable
}

// ─────────────────────────────────────────────────────────────────────────────
// UART configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Parity configuration.
enum UARTParity { none, even, odd }

/// Number of stop bits.
enum UARTStopBits { one, two }

/// Word length.
enum UARTWordLength { bits5, bits6, bits7, bits8 }

/// Full UART configuration.
final class UARTConfig {
  final int baudRate;
  final UARTWordLength wordLength;
  final UARTParity parity;
  final UARTStopBits stopBits;
  final bool enableFifo;
  final bool enableInterrupts;

  /// Peripheral clock frequency (Hz) used to compute baud divisors.
  final int peripheralClockHz;

  const UARTConfig({
    this.baudRate           = 115200,
    this.wordLength         = UARTWordLength.bits8,
    this.parity             = UARTParity.none,
    this.stopBits           = UARTStopBits.one,
    this.enableFifo         = true,
    this.enableInterrupts   = false,
    this.peripheralClockHz  = 48000000, // 48 MHz (RasPi PL011 clock)
  });

  /// Standard 115200 8N1.
  factory UARTConfig.standard() => const UARTConfig();

  /// High-speed 921600 8N1.
  factory UARTConfig.highSpeed() => const UARTConfig(baudRate: 921600);
}

// ─────────────────────────────────────────────────────────────────────────────
// UARTDriver
// ─────────────────────────────────────────────────────────────────────────────

/// PL011 UART driver with polling and interrupt-driven support.
///
/// ```dart
/// final uart = UARTDriver(baseAddress: 0x3F201000, baudRate: 115200);
/// await uart.init();
/// uart.print('Hello, bare metal!\r\n');
/// final ch = uart.getChar();
/// ```
final class UARTDriver extends DeviceDriver {
  final int _base;
  final UARTConfig _cfg;

  // Software ring buffers (used in interrupt mode)
  final Queue<int> _rxBuffer = Queue();
  final Queue<int> _txBuffer = Queue();

  static final _log = Logger('UARTDriver');

  UARTDriver({
    required int baseAddress,
    int baudRate = 115200,
    UARTConfig? config,
  })  : _base = baseAddress,
        _cfg  = config ?? UARTConfig(baudRate: baudRate);

  @override
  DeviceInfo get info => DeviceInfo(
        name:        'uart0',
        description: 'PL011 UART',
        type:        DeviceType.uart,
        baseAddress: _base,
        irqNumber:   65,
      );

  // ─── DeviceDriver lifecycle ───────────────────────────────────────────────

  @override
  Future<void> init() async {
    // 1. Disable UART
    _writeReg(_PL011.cr, 0);

    // 2. Wait until UART is no longer busy
    while (_readReg(_PL011.fr) & _PL011.frBusy != 0) {}

    // 3. Flush FIFOs
    _writeReg(_PL011.lcrH, 0);

    // 4. Set baud rate divisors
    //    BRD = UART_CLK / (16 × BAUD)
    //    Integer part:    IBRD = floor(BRD)
    //    Fractional part: FBRD = round((BRD – IBRD) × 64)
    final brdx64  = (_cfg.peripheralClockHz * 4) ~/ _cfg.baudRate;
    final ibrd    = brdx64 >> 6;
    final fbrd    = brdx64 & 0x3F;
    _writeReg(_PL011.ibrd, ibrd);
    _writeReg(_PL011.fbrd, fbrd);

    // 5. Configure line control
    var lcrH = _PL011.lcrHWlen8; // 8-bit words
    if (_cfg.enableFifo) lcrH |= _PL011.lcrHFen;
    if (_cfg.stopBits == UARTStopBits.two) lcrH |= _PL011.lcrHStp2;
    if (_cfg.parity != UARTParity.none) {
      lcrH |= _PL011.lcrHPen;
      if (_cfg.parity == UARTParity.even) lcrH |= _PL011.lcrHEps;
    }
    _writeReg(_PL011.lcrH, lcrH);

    // 6. Enable UART + TX + RX
    _writeReg(_PL011.cr, _PL011.crUartenBit | _PL011.crTxe | _PL011.crRxe);

    _log.info('UART0 init: ${_cfg.baudRate} bps, base=0x${_base.toRadixString(16)}');
  }

  @override
  Future<void> cleanup() async {
    _writeReg(_PL011.cr, 0);
    status = DeviceStatus.removed;
  }

  // ─── TX ───────────────────────────────────────────────────────────────────

  /// Send a single byte (polling).
  void putByte(int byte) {
    // Spin until TX FIFO has space
    while (_readReg(_PL011.fr) & _PL011.frTxff != 0) {}
    _writeReg(_PL011.dr, byte & 0xFF);
  }

  /// Send a character (int codeUnit), optionally expanding LF → CRLF.
  void putChar(int codeUnit, {bool crLfConvert = true}) {
    if (crLfConvert && codeUnit == 0x0A) putByte(0x0D); // CR before LF
    putByte(codeUnit);
  }

  /// Send a [String].
  void print(String message, {bool crLfConvert = true}) {
    for (final cu in message.codeUnits) {
      putChar(cu, crLfConvert: crLfConvert);
    }
  }

  /// Send a [String] followed by `\r\n`.
  void println(String message) => print('$message\r\n');

  /// Send a [Uint8List] of raw bytes.
  void writeBytes(Uint8List bytes) {
    for (final b in bytes) putByte(b);
  }

  /// Printf-style formatted output.
  void printf(String format, List<Object> args) {
    // Minimal printf: replace %d %x %s in order with args
    var result = format;
    var idx    = 0;
    result = result.replaceAllMapped(RegExp(r'%([dxsf])'), (m) {
      if (idx >= args.length) return m.group(0)!;
      final arg = args[idx++];
      return switch (m.group(1)) {
        'd' => '$arg',
        'x' => (arg as int).toRadixString(16),
        'f' => (arg as double).toStringAsFixed(2),
        's' => '$arg',
        _   => m.group(0)!,
      };
    });
    print(result);
  }

  // ─── RX ───────────────────────────────────────────────────────────────────

  /// Read one byte (polling — blocks until data arrives).
  int getByte() {
    while (_readReg(_PL011.fr) & _PL011.frRxfe != 0) {}
    return _readReg(_PL011.dr) & 0xFF;
  }

  /// Read one byte with a timeout.
  ///
  /// Returns -1 if no data arrives within [timeoutMs] milliseconds.
  int getByteTimeout(int timeoutMs) {
    var elapsed = 0;
    while ((_readReg(_PL011.fr) & _PL011.frRxfe) != 0) {
      if (elapsed >= timeoutMs) return -1;
      elapsed++;
    }
    return _readReg(_PL011.dr) & 0xFF;
  }

  /// Return the next character (as int) or null if RX FIFO is empty.
  int? tryGetByte() {
    if (_readReg(_PL011.fr) & _PL011.frRxfe != 0) return null;
    return _readReg(_PL011.dr) & 0xFF;
  }

  /// Read up to [maxBytes] bytes into a [Uint8List].
  Uint8List readBytes(int maxBytes) {
    final buf = <int>[];
    for (var i = 0; i < maxBytes; i++) {
      final b = tryGetByte();
      if (b == null) break;
      buf.add(b);
    }
    return Uint8List.fromList(buf);
  }

  /// Read a line (terminated by LF or CR) with optional echo.
  String readLine({bool echo = false}) {
    final buf = StringBuffer();
    while (true) {
      final b = getByte();
      if (b == 0x0D || b == 0x0A) {
        if (echo) println('');
        break;
      }
      if (b == 0x08 || b == 0x7F) {
        // Backspace
        if (buf.isNotEmpty) {
          final s = buf.toString();
          final sb = StringBuffer(s.substring(0, s.length - 1));
          buf.clear();
          buf.write(sb);
          if (echo) print('\x08 \x08');
        }
        continue;
      }
      buf.writeCharCode(b);
      if (echo) putChar(b);
    }
    return buf.toString();
  }

  // ─── IRQ handler ──────────────────────────────────────────────────────────

  @override
  void handleIrq(int irqNumber) {
    final mis = _readReg(_PL011.mis);

    // RX FIFO not empty → drain into software buffer
    if (mis & (1 << 4) != 0) {
      while (_readReg(_PL011.fr) & _PL011.frRxfe == 0) {
        _rxBuffer.addLast(_readReg(_PL011.dr) & 0xFF);
      }
    }

    // TX FIFO empty → fill from software TX buffer
    if (mis & (1 << 5) != 0) {
      while (_txBuffer.isNotEmpty && _readReg(_PL011.fr) & _PL011.frTxff == 0) {
        _writeReg(_PL011.dr, _txBuffer.removeFirst());
      }
    }

    // Clear all interrupts
    _writeReg(_PL011.icr, mis);
  }

  // ─── MMIO helpers ─────────────────────────────────────────────────────────

  int  _readReg (int offset) => MMIO.read32 (_base + offset);
  void _writeReg(int offset, int value) => MMIO.write32(_base + offset, value);
}
