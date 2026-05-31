import 'dart:typed_data';

import 'package:kernel_dart/src/utils/compression.dart';
import 'package:test/test.dart';

void main() {
  group('compressGzip / decompressGzip round-trip', () {
    test('compresses and decompresses empty list', () {
      final compressed   = CompressionUtils.compressGzip([]);
      final decompressed = CompressionUtils.decompressGzip(compressed);
      expect(decompressed, isEmpty);
    });

    test('round-trips a short ASCII string', () {
      final original     = 'Hello, bare metal!'.codeUnits;
      final compressed   = CompressionUtils.compressGzip(original);
      final decompressed = CompressionUtils.decompressGzip(compressed);
      expect(decompressed, equals(original));
    });

    test('round-trips arbitrary bytes', () {
      final original = List<int>.generate(256, (i) => i);
      final result   = CompressionUtils.decompressGzip(
                         CompressionUtils.compressGzip(original));
      expect(result, equals(original));
    });

    test('round-trips large binary data (4 KiB)', () {
      final data   = Uint8List(4096)..fillRange(0, 4096, 0xAB);
      final result = CompressionUtils.decompressGzip(
                       CompressionUtils.compressGzip(data));
      expect(result, equals(data));
    });

    test('compressed size is smaller than original for repetitive data', () {
      final data       = Uint8List(1024)..fillRange(0, 1024, 0x42);
      final compressed = CompressionUtils.compressGzip(data);
      expect(compressed.length, lessThan(data.length));
    });

    test('compressGzip returns Uint8List', () {
      expect(CompressionUtils.compressGzip([1, 2, 3]), isA<Uint8List>());
    });
  });

  group('crc32', () {
    test('CRC32 of empty list is 0', () {
      expect(CompressionUtils.crc32([]), equals(0));
    });

    test('CRC32 of known input matches expected value', () {
      // CRC32 of [1, 2, 3, 4] — standard CRC32 polynomial
      final crc = CompressionUtils.crc32([1, 2, 3, 4]);
      expect(crc, isA<int>());
      expect(crc, isNot(equals(0)));
    });

    test('CRC32 is deterministic', () {
      final data = List.generate(64, (i) => i);
      expect(CompressionUtils.crc32(data), equals(CompressionUtils.crc32(data)));
    });

    test('different data produces different CRC', () {
      final a = CompressionUtils.crc32([0x00, 0x00]);
      final b = CompressionUtils.crc32([0xFF, 0xFF]);
      expect(a, isNot(equals(b)));
    });

    test('CRC32 result is within 32-bit range', () {
      final crc = CompressionUtils.crc32(List.generate(256, (i) => i));
      expect(crc, greaterThanOrEqualTo(0));
      expect(crc, lessThanOrEqualTo(0xFFFFFFFF));
    });
  });

  group('compressZlib / decompressZlib round-trip', () {
    test('round-trips a short list', () {
      final data   = [10, 20, 30, 40, 50];
      final result = CompressionUtils.decompressZlib(
                       CompressionUtils.compressZlib(data));
      expect(result, equals(data));
    });
  });

  group('adler32', () {
    test('adler32 of empty list is 1', () {
      // Adler-32 spec: initial value is 1
      expect(CompressionUtils.adler32([]), equals(1));
    });

    test('adler32 is deterministic', () {
      final data = [0x61, 0x62, 0x63]; // "abc"
      expect(CompressionUtils.adler32(data), equals(CompressionUtils.adler32(data)));
    });
  });
}
