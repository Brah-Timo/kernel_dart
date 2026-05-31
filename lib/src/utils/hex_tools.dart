/// Hex dump, binary ↔ hex string conversion, and SREC / Intel HEX generation.
library;

import 'dart:typed_data';

/// Hex utility functions for binary analysis and embedded development.
abstract final class HexTools {
  // ─── Byte ↔ hex string ────────────────────────────────────────────────────

  /// Convert a byte [value] to a 2-char hex string (`'1F'`).
  static String byte2hex(int value, {bool upperCase = true}) {
    final s = (value & 0xFF).toRadixString(16).padLeft(2, '0');
    return upperCase ? s.toUpperCase() : s;
  }

  /// Parse a hex string (`'1F'`) to an integer.
  static int hex2byte(String hex) => int.parse(hex.trim(), radix: 16);

  /// Convert [bytes] to a continuous hex string (e.g. `'DEADBEEF'`).
  static String toHexString(List<int> bytes, {bool upperCase = true, String sep = ''}) {
    final s = bytes.map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join(sep);
    return upperCase ? s.toUpperCase() : s;
  }

  /// Parse a hex string (with optional spaces / colons) to a [Uint8List].
  static Uint8List fromHexString(String hex) {
    final clean = hex.replaceAll(RegExp(r'[\s:_-]'), '');
    if (clean.length % 2 != 0) throw FormatException('Odd-length hex string');
    return Uint8List.fromList([
      for (var i = 0; i < clean.length; i += 2)
        int.parse(clean.substring(i, i + 2), radix: 16),
    ]);
  }

  // ─── Hex dump ────────────────────────────────────────────────────────────

  /// Produce a human-readable hex dump (like `xxd`).
  ///
  /// ```
  /// 00000000  48 65 6C 6C 6F 20 44 61  72 74 20 42 61 72 65 4D  |Hello Dart BareM|
  /// 00000010  65 74 61 6C 0A                                     |etal.|
  /// ```
  static String hexDump(
    List<int> bytes, {
    int bytesPerLine = 16,
    int startAddress = 0,
  }) {
    final buf = StringBuffer();

    for (var i = 0; i < bytes.length; i += bytesPerLine) {
      final end     = (i + bytesPerLine).clamp(0, bytes.length);
      final line    = bytes.sublist(i, end);
      final addr    = (startAddress + i).toRadixString(16).padLeft(8, '0').toUpperCase();
      final hexPart = line
          .asMap()
          .entries
          .map((e) {
            final s = byte2hex(e.value);
            return e.key == 7 ? '$s  ' : '$s '; // extra space at midpoint
          })
          .join()
          .padRight(bytesPerLine * 3 + 1);

      final asciiPart = line
          .map((b) => (b >= 0x20 && b < 0x7F) ? String.fromCharCode(b) : '.')
          .join();

      buf.writeln('$addr  $hexPart |$asciiPart|');
    }

    return buf.toString();
  }

  // ─── Intel HEX (.hex) ─────────────────────────────────────────────────────

  /// Generate an Intel HEX file from [data] starting at [baseAddress].
  static String toIntelHex(List<int> data, {int baseAddress = 0}) {
    const maxRecordBytes = 16;
    final buf = StringBuffer();

    // If base address > 64 KB, emit Extended Linear Address record
    if (baseAddress > 0xFFFF) {
      final hi    = (baseAddress >> 16) & 0xFFFF;
      final bytes = [0x00, 0x00, 0x04, (hi >> 8) & 0xFF, hi & 0xFF];
      final csum  = _intelChecksum(bytes);
      buf.writeln(':${byte2hex(bytes.length)}0000${toHexString(bytes)}${byte2hex(csum)}');
    }

    var offset = 0;
    while (offset < data.length) {
      final end    = (offset + maxRecordBytes).clamp(0, data.length);
      final chunk  = data.sublist(offset, end);
      final addr   = (baseAddress + offset) & 0xFFFF;
      final addrHi = (addr >> 8) & 0xFF;
      final addrLo = addr & 0xFF;

      final recordHeader = [chunk.length, addrHi, addrLo, 0x00];
      final fullRecord   = [...recordHeader, ...chunk];
      final csum = _intelChecksum(fullRecord);

      buf.writeln(':${byte2hex(chunk.length)}'
          '${byte2hex(addrHi)}${byte2hex(addrLo)}'
          '00'
          '${toHexString(chunk)}'
          '${byte2hex(csum)}');

      offset = end;
    }

    buf.writeln(':00000001FF'); // EOF record
    return buf.toString();
  }

  /// Parse an Intel HEX file and return the binary [data, baseAddress].
  static ({Uint8List data, int baseAddress}) fromIntelHex(String hexText) {
    var extLinearBase = 0;
    var minAddr       = 0x7FFFFFFF;
    var maxAddr       = 0;

    final records = <({int addr, List<int> data})>[];

    for (final line in hexText.split('\n')) {
      final l = line.trim();
      if (l.isEmpty || !l.startsWith(':')) continue;

      final byteCount = int.parse(l.substring(1, 3), radix: 16);
      final addr      = int.parse(l.substring(3, 7), radix: 16);
      final recType   = int.parse(l.substring(7, 9), radix: 16);
      final dataHex   = l.substring(9, 9 + byteCount * 2);

      switch (recType) {
        case 0x00: // Data
          final physAddr = extLinearBase + addr;
          final bytes    = [
            for (var i = 0; i < dataHex.length; i += 2)
              int.parse(dataHex.substring(i, i + 2), radix: 16),
          ];
          records.add((addr: physAddr, data: bytes));
          if (physAddr < minAddr) minAddr = physAddr;
          if (physAddr + bytes.length > maxAddr) maxAddr = physAddr + bytes.length;
        case 0x04: // Extended Linear Address
          extLinearBase = int.parse(dataHex, radix: 16) << 16;
        case 0x01: break; // EOF
      }
    }

    final buf = Uint8List(maxAddr - minAddr)..fillRange(0, maxAddr - minAddr, 0xFF);
    for (final r in records) {
      buf.setRange(r.addr - minAddr, r.addr - minAddr + r.data.length, r.data);
    }

    return (data: buf, baseAddress: minAddr);
  }

  // ─── Motorola SREC ────────────────────────────────────────────────────────

  /// Generate a Motorola S-Record file from [data] starting at [baseAddress].
  static String toSRec(List<int> data, {int baseAddress = 0, String filename = 'kernel'}) {
    const maxDataBytes = 28;
    final buf = StringBuffer();

    // S0 header
    final header = [...filename.codeUnits];
    buf.writeln('S0${byte2hex(header.length + 3)}0000${toHexString(header)}'
        '${byte2hex(_srecChecksum(header.length + 3, 0, header))}');

    // S3 / S2 / S1 data records
    var offset = 0;
    while (offset < data.length) {
      final end   = (offset + maxDataBytes).clamp(0, data.length);
      final chunk = data.sublist(offset, end);
      final addr  = baseAddress + offset;
      final ab    = [
        (addr >> 24) & 0xFF, (addr >> 16) & 0xFF,
        (addr >>  8) & 0xFF,  addr        & 0xFF,
      ];
      final len = ab.length + chunk.length + 1; // +1 for checksum
      buf.writeln('S3${byte2hex(len)}${toHexString(ab)}${toHexString(chunk)}'
          '${byte2hex(_srecChecksum(len, addr, chunk))}');
      offset = end;
    }

    // S7 end record (32-bit address)
    buf.writeln('S70500000000FA');
    return buf.toString();
  }

  // ─── Internal checksum helpers ────────────────────────────────────────────

  static int _intelChecksum(List<int> bytes) {
    final sum = bytes.fold(0, (a, b) => a + b) & 0xFF;
    return ((~sum) + 1) & 0xFF;
  }

  static int _srecChecksum(int byteCount, int addr, List<int> data) {
    var sum = byteCount;
    sum += (addr >> 24) & 0xFF;
    sum += (addr >> 16) & 0xFF;
    sum += (addr >>  8) & 0xFF;
    sum +=  addr        & 0xFF;
    sum += data.fold(0, (a, b) => a + b);
    return (~sum) & 0xFF;
  }
}
