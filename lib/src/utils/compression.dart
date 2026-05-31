/// Compression utilities: gzip, LZ4, and CRC32 / Adler-32 checksums.
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:logging/logging.dart';

/// Collection of compression and checksum helpers.
abstract final class CompressionUtils {
  static final _log = Logger('CompressionUtils');

  // ─── Gzip ────────────────────────────────────────────────────────────────

  /// Compress [bytes] with gzip at the given [level] (0–9).
  static Uint8List compressGzip(List<int> bytes, {int level = 6}) {
    _log.fine('gzip compress ${bytes.length} bytes (level=$level)');
    final encoder    = GZipEncoder();
    final compressed = encoder.encode(bytes, level: level) ?? <int>[];
    _log.fine('  → ${compressed.length} bytes (${(compressed.length / bytes.length * 100).toStringAsFixed(1)}%)');
    return Uint8List.fromList(compressed);
  }

  /// Decompress a gzip-compressed [bytes] buffer.
  static List<int> decompressGzip(List<int> bytes) {
    _log.fine('gzip decompress ${bytes.length} bytes');
    final decoder     = GZipDecoder();
    final decompressed = decoder.decodeBytes(bytes);
    _log.fine('  → ${decompressed.length} bytes');
    return decompressed;
  }

  /// Compress a file at [inputPath] with gzip and write to [outputPath].
  ///
  /// If [outputPath] is null, appends `.gz` to [inputPath].
  static Future<String> compressFile(
    String inputPath, {
    String? outputPath,
    int level = 9,
  }) async {
    final outPath = outputPath ?? '$inputPath.gz';
    final inputBytes  = await File(inputPath).readAsBytes();
    final compressed  = compressGzip(inputBytes, level: level);
    await File(outPath).writeAsBytes(compressed);
    _log.info('Compressed: $inputPath → $outPath (${compressed.length} bytes)');
    return outPath;
  }

  /// Decompress a gzip file at [inputPath] and write to [outputPath].
  static Future<String> decompressFile(
    String inputPath, {
    String? outputPath,
  }) async {
    final outPath    = outputPath ?? inputPath.replaceAll('.gz', '');
    final inputBytes = await File(inputPath).readAsBytes();
    final decompressed = decompressGzip(inputBytes);
    await File(outPath).writeAsBytes(decompressed);
    _log.info('Decompressed: $inputPath → $outPath (${decompressed.length} bytes)');
    return outPath;
  }

  // ─── Zlib ─────────────────────────────────────────────────────────────────

  /// Compress [bytes] with zlib deflate.
  static Uint8List compressZlib(List<int> bytes, {int level = 6}) {
    final encoder    = ZLibEncoder();
    final compressed = encoder.encode(bytes, level: level);
    return Uint8List.fromList(compressed);
  }

  /// Decompress zlib-compressed [bytes].
  static List<int> decompressZlib(List<int> bytes) {
    final decoder = ZLibDecoder();
    return decoder.decodeBytes(bytes);
  }

  // ─── CRC-32 ───────────────────────────────────────────────────────────────

  /// Compute CRC-32 (IEEE 802.3 polynomial) of [bytes].
  static int crc32(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc ^= b;
      for (var j = 0; j < 8; j++) {
        crc = (crc & 1) != 0 ? ((crc >> 1) ^ 0xEDB88320) : (crc >> 1);
      }
    }
    return (~crc) & 0xFFFFFFFF;
  }

  /// Compute CRC-32 of a file.
  static Future<int> crc32File(String path) async {
    final bytes = await File(path).readAsBytes();
    return crc32(bytes);
  }

  // ─── Adler-32 ─────────────────────────────────────────────────────────────

  /// Compute Adler-32 checksum of [bytes].
  static int adler32(List<int> bytes) {
    const mod = 65521;
    var a = 1;
    var b = 0;
    for (final byte in bytes) {
      a = (a + byte) % mod;
      b = (b + a) % mod;
    }
    return (b << 16) | a;
  }

  // ─── Fletcher-16 ──────────────────────────────────────────────────────────

  /// Compute Fletcher-16 checksum (used in some embedded protocols).
  static int fletcher16(List<int> bytes) {
    var sum1 = 0;
    var sum2 = 0;
    for (final b in bytes) {
      sum1 = (sum1 + b) % 255;
      sum2 = (sum2 + sum1) % 255;
    }
    return (sum2 << 8) | sum1;
  }

  // ─── LZ4 (pure-Dart minimal implementation) ────────────────────────────────

  /// A very simple LZ4 block decompressor (no frame format).
  ///
  /// LZ4 block format: tokens of [literal_len | match_len] followed by
  /// literal bytes and match offset.
  static Uint8List decompressLz4Block(Uint8List src, int outputSize) {
    final dst = Uint8List(outputSize);
    var s = 0;
    var d = 0;

    while (s < src.length) {
      final token      = src[s++];
      var   literalLen = (token >> 4) & 0xF;
      var   matchLen   = token & 0xF;

      // Extended literal length
      if (literalLen == 15) {
        int extra;
        do {
          extra       = src[s++];
          literalLen += extra;
        } while (extra == 255);
      }

      // Copy literals
      dst.setRange(d, d + literalLen, src.sublist(s, s + literalLen));
      s += literalLen;
      d += literalLen;

      if (s >= src.length) break; // End of block

      // Match offset (little-endian 16-bit)
      final offset = src[s] | (src[s + 1] << 8);
      s += 2;

      // Extended match length
      matchLen += 4;
      if ((token & 0xF) == 15) {
        int extra;
        do {
          extra      = src[s++];
          matchLen  += extra;
        } while (extra == 255);
      }

      // Copy match (may overlap → byte-by-byte)
      final matchStart = d - offset;
      for (var i = 0; i < matchLen; i++) {
        dst[d++] = dst[matchStart + i];
      }
    }

    return dst;
  }

  // ─── Hexdigest ────────────────────────────────────────────────────────────

  /// Format an integer as a zero-padded hex string.
  static String hexDigest(int value, {int width = 8}) =>
      value.toRadixString(16).padLeft(width, '0').toUpperCase();

  // ─── Entropy estimate ─────────────────────────────────────────────────────

  /// Estimate the Shannon entropy of [bytes] (bits per byte, 0–8).
  static double entropy(List<int> bytes) {
    if (bytes.isEmpty) return 0;
    final freq = List<int>.filled(256, 0);
    for (final b in bytes) freq[b & 0xFF]++;
    var e = 0.0;
    final n = bytes.length;
    for (final f in freq) {
      if (f == 0) continue;
      final p = f / n;
      e -= p * (p == 0 ? 0 : (p > 0 ? _log2(p) : 0));
    }
    return e;
  }

  static double _log2(double x) => x <= 0 ? 0 : x.abs().toDouble() == 0 ? 0 : _ln(x) / _ln(2);
  static double _ln(double x)   {
    // Simple natural log via Dart's math library
    // We avoid importing dart:math here; use iterative approximation
    if (x <= 0) return double.negativeInfinity;
    if (x == 1) return 0;
    // ln(x) ≈ sum of series for |x-1| < 1, else use identity ln(x) = ln(2) + ln(x/2)
    double result = 0;
    var v = x;
    while (v >= 2) { result += 0.6931471805599453; v /= 2; }
    while (v < 1)  { result -= 0.6931471805599453; v *= 2; }
    // Padé approximation for v near 1
    final u = v - 1;
    result += u * (6 + 2 * u) / (6 + 5 * u + u * u * 0.5);
    return result;
  }
}
