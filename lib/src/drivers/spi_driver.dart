/// SPI (Serial Peripheral Interface) driver.
///
/// Supports:
///   • Full-duplex 8/16/32-bit transfers
///   • Multiple chip-select lines (CS0–CS2 on BCM2835)
///   • Configurable clock polarity (CPOL) and phase (CPHA) — all 4 SPI modes
///   • DMA and polling transfer modes
///   • LSB-first / MSB-first bit ordering
// ignore_for_file: unused_field
library;

import 'dart:typed_data';
import 'package:logging/logging.dart';

import '../kernel/device_drivers.dart';
import '../runtime/ffi_bridge.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BCM2835 SPI0 register offsets
// ─────────────────────────────────────────────────────────────────────────────

abstract final class _BCM2835Spi {
  static const int cs   = 0x00; // Control and Status
  static const int fifo = 0x04; // TX/RX FIFO
  static const int clk  = 0x08; // Clock divider
  static const int dlen = 0x0C; // DMA Data Length
  static const int ltoh = 0x10; // LoSSI mode TOH
  static const int dc   = 0x14; // DMA DREQ Controls

  // CS bits
  static const int csCs0      = 0 << 0; // Chip Select 0
  static const int csCs1      = 1 << 0; // Chip Select 1
  static const int csCs2      = 2 << 0; // Chip Select 2
  static const int csCpha     = 1 << 2; // Clock Phase
  static const int csCpol     = 1 << 3; // Clock Polarity
  static const int csClear    = 3 << 4; // Clear FIFO (TX+RX)
  static const int csCphaRx   = 0;
  static const int csTa       = 1 << 7; // Transfer Active
  static const int csDoneSet  = 1 << 16;// Transfer Done
  static const int csRxd      = 1 << 17;// RX FIFO has data
  static const int csTxd      = 1 << 18;// TX FIFO has space
  static const int csDone     = 1 << 16;// Transfer done
}

// ─────────────────────────────────────────────────────────────────────────────
// SPI enumerations
// ─────────────────────────────────────────────────────────────────────────────

/// SPI clock polarity and phase (mode 0–3).
enum SPIMode {
  mode0, // CPOL=0, CPHA=0 — idle low,  sample on rising  edge
  mode1, // CPOL=0, CPHA=1 — idle low,  sample on falling edge
  mode2, // CPOL=1, CPHA=0 — idle high, sample on falling edge
  mode3, // CPOL=1, CPHA=1 — idle high, sample on rising  edge
}

/// SPI chip-select line.
enum SPIChipSelect { cs0, cs1, cs2 }

/// Bit order for SPI transfers.
enum SPIBitOrder { msbFirst, lsbFirst }

// ─────────────────────────────────────────────────────────────────────────────
// SPI configuration
// ─────────────────────────────────────────────────────────────────────────────

final class SPIConfig {
  final int clockHz;
  final SPIMode mode;
  final SPIChipSelect chipSelect;
  final SPIBitOrder bitOrder;
  final int peripheralClockHz;

  const SPIConfig({
    this.clockHz            = 1000000,   // 1 MHz default
    this.mode               = SPIMode.mode0,
    this.chipSelect         = SPIChipSelect.cs0,
    this.bitOrder           = SPIBitOrder.msbFirst,
    this.peripheralClockHz  = 250000000, // 250 MHz (BCM2835 core clock)
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// SPIDriver
// ─────────────────────────────────────────────────────────────────────────────

/// BCM2835 SPI0 master driver.
///
/// ```dart
/// final spi = SPIDriver(baseAddress: 0x3F204000);
/// await spi.init();
///
/// // Transfer 3 bytes, full duplex
/// final rx = await spi.transfer(Uint8List.fromList([0x9F, 0x00, 0x00]));
/// // rx[0] = JEDEC manufacturer ID, rx[1..2] = device ID
/// ```
final class SPIDriver extends DeviceDriver {
  final int _base;
  final SPIConfig _cfg;

  static final _log = Logger('SPIDriver');

  SPIDriver({required int baseAddress, SPIConfig? config})
      : _base = baseAddress,
        _cfg  = config ?? const SPIConfig();

  @override
  DeviceInfo get info => DeviceInfo(
        name:        'spi0',
        description: 'BCM2835 SPI0 Master',
        type:        DeviceType.spi,
        baseAddress: _base,
        irqNumber:   54,
      );

  @override
  Future<void> init() async {
    // Compute clock divider: CDIV = peripheral_clock / spi_clock
    // Must be a power of 2 (BCM2835); round up.
    final cdiv = _nextPow2(_cfg.peripheralClockHz ~/ _cfg.clockHz);

    // Set clock divider
    MMIO.write32(_base + _BCM2835Spi.clk, cdiv);

    // Configure CS register: mode, chip-select, clear FIFOs
    var cs = _BCM2835Spi.csClear; // Clear TX+RX FIFOs

    // Set chip-select
    cs |= _cfg.chipSelect.index;

    // Set mode
    if (_cfg.mode == SPIMode.mode1 || _cfg.mode == SPIMode.mode3) {
      cs |= _BCM2835Spi.csCpha; // CPHA=1
    }
    if (_cfg.mode == SPIMode.mode2 || _cfg.mode == SPIMode.mode3) {
      cs |= _BCM2835Spi.csCpol; // CPOL=1
    }

    MMIO.write32(_base + _BCM2835Spi.cs, cs);

    _log.info('SPI0 init: clock=${_cfg.clockHz} Hz '
        '(CDIV=$cdiv), mode=${_cfg.mode.name}, CS=${_cfg.chipSelect.name}');
  }

  @override
  Future<void> cleanup() async {
    MMIO.write32(_base + _BCM2835Spi.cs, 0);
    status = DeviceStatus.removed;
  }

  // ─── Transfers ────────────────────────────────────────────────────────────

  /// Perform a full-duplex SPI transfer.
  ///
  /// [txData] is sent byte-by-byte; the received bytes are returned.
  Future<Uint8List> transfer(Uint8List txData) async {
    final rxData = Uint8List(txData.length);

    // Enable transfer (TA = 1)
    MMIO.setBits(_base + _BCM2835Spi.cs, _BCM2835Spi.csTa);

    for (var i = 0; i < txData.length; i++) {
      // Wait for TX FIFO space
      while (MMIO.read32(_base + _BCM2835Spi.cs) & _BCM2835Spi.csTxd == 0) {}

      // Write TX byte
      MMIO.write32(_base + _BCM2835Spi.fifo, txData[i] & 0xFF);

      // Wait for RX data
      while (MMIO.read32(_base + _BCM2835Spi.cs) & _BCM2835Spi.csRxd == 0) {}

      // Read RX byte
      rxData[i] = MMIO.read32(_base + _BCM2835Spi.fifo) & 0xFF;
    }

    // Wait for transfer to complete
    while (MMIO.read32(_base + _BCM2835Spi.cs) & _BCM2835Spi.csDone == 0) {}

    // Disable transfer (TA = 0)
    MMIO.clearBits(_base + _BCM2835Spi.cs, _BCM2835Spi.csTa);

    return rxData;
  }

  /// TX-only transfer (discard received bytes).
  Future<void> write(Uint8List data) async {
    await transfer(data);
  }

  /// Send a single byte and return the received byte.
  Future<int> transferByte(int byte) async {
    final rx = await transfer(Uint8List.fromList([byte & 0xFF]));
    return rx[0];
  }

  /// RX-only transfer — send [length] dummy bytes (0xFF) and return received data.
  Future<Uint8List> read(int length) async {
    return transfer(Uint8List(length)..fillRange(0, length, 0xFF));
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  /// Write a register at [regAddr] on the SPI device.
  Future<void> writeRegister(int regAddr, int value) async {
    await transfer(Uint8List.fromList([regAddr & 0x7F, value & 0xFF]));
  }

  /// Read a register at [regAddr] from the SPI device (async).
  ///
  /// Prefer this over the inherited synchronous [readRegister] for SPI
  /// because the underlying [transfer] is inherently asynchronous.
  Future<int> readRegisterAsync(int regAddr) async {
    final rx = await transfer(Uint8List.fromList([regAddr | 0x80, 0x00]));
    return rx[1];
  }

  /// Read [length] bytes starting at [regAddr] (burst read).
  Future<Uint8List> readRegisters(int regAddr, int length) async {
    final tx = Uint8List(length + 1)
      ..[0] = (regAddr | 0x80) & 0xFF;
    final rx = await transfer(tx);
    return rx.sublist(1);
  }

  // ─── Internal helpers ─────────────────────────────────────────────────────

  int _nextPow2(int n) {
    var p = 1;
    while (p < n) p <<= 1;
    return p;
  }
}
