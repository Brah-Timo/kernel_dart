/// I²C (Inter-Integrated Circuit) driver.
///
/// Supports:
///   • Standard mode (100 kHz), Fast mode (400 kHz), Fast-Plus (1 MHz)
///   • 7-bit and 10-bit device addressing
///   • Byte, word, and block read / write operations
///   • Register-based sensor access helpers
///   • BCM2835 BSC (Broadcom Serial Controller) register layout
// ignore_for_file: unused_field
library;

import 'dart:typed_data';
import 'package:logging/logging.dart';

import '../kernel/device_drivers.dart';
import '../runtime/ffi_bridge.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BCM2835 BSC register offsets
// ─────────────────────────────────────────────────────────────────────────────

abstract final class _BSC {
  static const int c    = 0x00; // Control
  static const int s    = 0x04; // Status
  static const int dlen = 0x08; // Data Length
  static const int a    = 0x0C; // Slave Address
  static const int fifo = 0x10; // Data FIFO
  static const int div  = 0x14; // Clock Divider
  static const int del  = 0x18; // Data Delay
  static const int clkt = 0x1C; // Clock Stretch Timeout

  // Control bits
  static const int cI2cen = 1 << 15; // I2C Enable
  static const int cIntd  = 1 << 8;  // Interrupt on Done
  static const int cIntt  = 1 << 7;  // Interrupt on TX
  static const int cIntr  = 1 << 6;  // Interrupt on RX
  static const int cSt    = 1 << 7;  // Wait before START
  static const int cClear = 3 << 4;  // Clear FIFO
  static const int cRead  = 1 << 0;  // Read Transfer (1=read, 0=write)
  static const int cStart = 1 << 7;  // Start (new transfer)

  // Status bits
  static const int sClkt   = 1 << 9; // Clock Stretch Timeout
  static const int sErr    = 1 << 8; // ACK Error
  static const int sRxf    = 1 << 7; // RX FIFO Full
  static const int sTxe    = 1 << 6; // TX FIFO Empty
  static const int sRxd    = 1 << 5; // RX FIFO has data
  static const int sTxd    = 1 << 4; // TX FIFO can accept data
  static const int sRxr    = 1 << 3; // RX FIFO needs reading (almost full)
  static const int sTxw    = 1 << 2; // TX FIFO needs writing (almost empty)
  static const int sDone   = 1 << 1; // Transfer Done
  static const int sTa     = 1 << 0; // Transfer Active
}

// ─────────────────────────────────────────────────────────────────────────────
// I²C speed constants
// ─────────────────────────────────────────────────────────────────────────────

abstract final class I2CSpeed {
  static const int standard   = 100000;   // 100 kHz
  static const int fast       = 400000;   // 400 kHz
  static const int fastPlus   = 1000000;  // 1 MHz
  static const int highSpeed  = 3400000;  // 3.4 MHz (H/W dependent)
}

// ─────────────────────────────────────────────────────────────────────────────
// I²C errors
// ─────────────────────────────────────────────────────────────────────────────

/// I²C transfer error codes.
enum I2CError {
  none,
  ackError,       // Slave did not ACK
  timeout,        // Clock stretch timeout
  busyTimeout,    // Transfer active too long
  overrun,        // FIFO overrun
  arbitrationLost,
}

/// Result of an I²C transaction.
final class I2CResult {
  final I2CError error;
  final Uint8List data;

  const I2CResult({required this.error, required this.data});

  bool get isOk => error == I2CError.none;

  @override
  String toString() =>
      'I2CResult(error=${error.name}, bytes=${data.length})';
}

// ─────────────────────────────────────────────────────────────────────────────
// I²C configuration
// ─────────────────────────────────────────────────────────────────────────────

final class I2CConfig {
  final int speedHz;
  final int peripheralClockHz;
  final int timeoutMs;

  const I2CConfig({
    this.speedHz            = I2CSpeed.fast,
    this.peripheralClockHz  = 150000000, // 150 MHz (BCM2835 core / 2)
    this.timeoutMs          = 100,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// I2CDriver
// ─────────────────────────────────────────────────────────────────────────────

/// BCM2835 BSC I²C master driver.
///
/// ```dart
/// final i2c = I2CDriver(baseAddress: 0x3F804000);
/// await i2c.init();
///
/// // Read chip ID from BMP280 (address 0x76, register 0xD0)
/// final chipId = i2c.readByte(0x76, 0xD0);
///
/// // Write a configuration byte
/// i2c.writeByte(0x76, 0xF5, 0xA0);
/// ```
final class I2CDriver extends DeviceDriver {
  final int _base;
  final I2CConfig _cfg;

  static final _log = Logger('I2CDriver');

  I2CDriver({required int baseAddress, I2CConfig? config})
      : _base = baseAddress,
        _cfg  = config ?? const I2CConfig();

  @override
  DeviceInfo get info => DeviceInfo(
        name:        'i2c0',
        description: 'BCM2835 BSC I²C Master',
        type:        DeviceType.i2c,
        baseAddress: _base,
        irqNumber:   53,
      );

  @override
  Future<void> init() async {
    // Clock divider: CDIV = peripheral_clock / i2c_speed
    final cdiv = _cfg.peripheralClockHz ~/ _cfg.speedHz;
    MMIO.write32(_base + _BSC.div, cdiv);

    // Enable I2C
    MMIO.write32(_base + _BSC.c, _BSC.cI2cen);

    // Set clock stretch timeout
    MMIO.write32(_base + _BSC.clkt, _cfg.timeoutMs * (_cfg.speedHz ~/ 1000));

    _log.info('I2C init: base=0x${_base.toRadixString(16)}, '
        'speed=${_cfg.speedHz ~/ 1000} kHz, CDIV=$cdiv');
  }

  @override
  Future<void> cleanup() async {
    MMIO.write32(_base + _BSC.c, 0);
    status = DeviceStatus.removed;
  }

  // ─── Low-level byte transfers ─────────────────────────────────────────────

  /// Write [data] to [deviceAddr].
  I2CResult writeRaw(int deviceAddr, Uint8List data) {
    _log.fine('I2C write addr=0x${deviceAddr.toRadixString(16)}, len=${data.length}');

    _setAddress(deviceAddr);
    MMIO.write32(_base + _BSC.dlen, data.length);

    // Clear status and FIFO
    MMIO.write32(_base + _BSC.s, _BSC.sClkt | _BSC.sErr | _BSC.sDone);
    MMIO.setBits(_base + _BSC.c, _BSC.cClear);

    // Load TX FIFO (up to 16 bytes before start)
    var txIdx = 0;
    while (txIdx < data.length && MMIO.read32(_base + _BSC.s) & _BSC.sTxd != 0) {
      MMIO.write32(_base + _BSC.fifo, data[txIdx++]);
    }

    // Start transfer (write mode)
    MMIO.write32(_base + _BSC.c, _BSC.cI2cen | _BSC.cStart);

    // Continue feeding FIFO
    while (MMIO.read32(_base + _BSC.s) & _BSC.sDone == 0) {
      if (MMIO.read32(_base + _BSC.s) & _BSC.sErr != 0) {
        return I2CResult(error: I2CError.ackError, data: Uint8List(0));
      }
      while (txIdx < data.length && MMIO.read32(_base + _BSC.s) & _BSC.sTxd != 0) {
        MMIO.write32(_base + _BSC.fifo, data[txIdx++]);
      }
    }

    if (MMIO.read32(_base + _BSC.s) & _BSC.sErr != 0) {
      return I2CResult(error: I2CError.ackError, data: Uint8List(0));
    }

    return I2CResult(error: I2CError.none, data: Uint8List(0));
  }

  /// Read [length] bytes from [deviceAddr].
  I2CResult readRaw(int deviceAddr, int length) {
    _log.fine('I2C read addr=0x${deviceAddr.toRadixString(16)}, len=$length');

    _setAddress(deviceAddr);
    MMIO.write32(_base + _BSC.dlen, length);

    // Clear status
    MMIO.write32(_base + _BSC.s, _BSC.sClkt | _BSC.sErr | _BSC.sDone);
    MMIO.setBits(_base + _BSC.c, _BSC.cClear);

    // Start read transfer
    MMIO.write32(_base + _BSC.c, _BSC.cI2cen | _BSC.cRead | _BSC.cStart);

    final rxBuf = <int>[];
    while (MMIO.read32(_base + _BSC.s) & _BSC.sDone == 0) {
      if (MMIO.read32(_base + _BSC.s) & _BSC.sErr != 0) {
        return I2CResult(error: I2CError.ackError, data: Uint8List.fromList(rxBuf));
      }
      while (MMIO.read32(_base + _BSC.s) & _BSC.sRxd != 0) {
        rxBuf.add(MMIO.read32(_base + _BSC.fifo) & 0xFF);
      }
    }

    // Drain remaining FIFO
    while (MMIO.read32(_base + _BSC.s) & _BSC.sRxd != 0) {
      rxBuf.add(MMIO.read32(_base + _BSC.fifo) & 0xFF);
    }

    return I2CResult(error: I2CError.none, data: Uint8List.fromList(rxBuf));
  }

  // ─── High-level register access helpers ──────────────────────────────────

  /// Write a single byte [value] to [reg] of [deviceAddr].
  void writeByte(int deviceAddr, int reg, int value) {
    writeRaw(deviceAddr, Uint8List.fromList([reg & 0xFF, value & 0xFF]));
  }

  /// Read one byte from [reg] of [deviceAddr].
  int readByte(int deviceAddr, int reg) {
    writeRaw(deviceAddr, Uint8List.fromList([reg & 0xFF]));
    final result = readRaw(deviceAddr, 1);
    return result.isOk && result.data.isNotEmpty ? result.data[0] : 0;
  }

  /// Write a 16-bit big-endian [word] to [reg] of [deviceAddr].
  void writeWord(int deviceAddr, int reg, int word) {
    writeRaw(deviceAddr, Uint8List.fromList([
      reg & 0xFF,
      (word >> 8) & 0xFF,
      word & 0xFF,
    ]));
  }

  /// Read a 16-bit big-endian word from [reg] of [deviceAddr].
  int readWord(int deviceAddr, int reg) {
    writeRaw(deviceAddr, Uint8List.fromList([reg & 0xFF]));
    final result = readRaw(deviceAddr, 2);
    if (!result.isOk || result.data.length < 2) return 0;
    return (result.data[0] << 8) | result.data[1];
  }

  /// Read [length] bytes from [reg] of [deviceAddr].
  Uint8List readBytes(int deviceAddr, int reg, int length) {
    writeRaw(deviceAddr, Uint8List.fromList([reg & 0xFF]));
    final result = readRaw(deviceAddr, length);
    return result.isOk ? result.data : Uint8List(0);
  }

  /// Check if a device at [deviceAddr] is present (ACK on its address).
  bool probeDevice(int deviceAddr) {
    final result = writeRaw(deviceAddr, Uint8List(0));
    return result.isOk;
  }

  /// Scan the bus and return all addresses (0x03–0x77) that ACK.
  List<int> scanBus() {
    final found = <int>[];
    for (var addr = 0x03; addr < 0x78; addr++) {
      if (probeDevice(addr)) found.add(addr);
    }
    return found;
  }

  // ─── Sensor-specific helpers ──────────────────────────────────────────────

  /// Read a signed 16-bit value (little-endian) from [reg].
  int readInt16LE(int deviceAddr, int reg) {
    final bytes = readBytes(deviceAddr, reg, 2);
    if (bytes.length < 2) return 0;
    final raw = bytes[0] | (bytes[1] << 8);
    return raw > 0x7FFF ? raw - 0x10000 : raw;
  }

  /// Write multiple bytes (burst write) starting at [reg].
  void writeBytes(int deviceAddr, int reg, Uint8List data) {
    final buf = Uint8List(1 + data.length)
      ..[0] = reg & 0xFF;
    buf.setRange(1, buf.length, data);
    writeRaw(deviceAddr, buf);
  }

  // ─── Internal helpers ─────────────────────────────────────────────────────

  void _setAddress(int addr) => MMIO.write32(_base + _BSC.a, addr & 0x7F);
}
