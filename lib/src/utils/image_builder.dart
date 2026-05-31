/// Bootable image builder — assembles all binary artefacts into a single
/// flashable image file.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:kernel_dart/src/compiler/dart_compiler.dart';
import 'package:kernel_dart/src/config/platform_config.dart';
import 'package:kernel_dart/src/utils/compression.dart';
import 'package:kernel_dart/src/utils/hex_tools.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
// ImageHeader
// ─────────────────────────────────────────────────────────────────────────────

/// 64-byte header prepended to every kernel_dart image.
final class ImageHeader {
  const ImageHeader({
    required this.imageSize,
    required this.loadAddress,
    required this.entryPoint,
    required this.kernelSize,
    required this.crc32,
    required this.compressed,
    required this.platform,
  });

  static const int magic       = 0x4B445254;  // 'KDRT'
  static const int version     = 1;
  static const int headerSize  = 64;

  final int imageSize;
  final int loadAddress;
  final int entryPoint;
  final int kernelSize;
  final int crc32;
  final bool compressed;
  final PlatformConfig platform;

  Uint8List encode() {
    final buf = ByteData(headerSize);
    buf.setUint32(0,  magic,       Endian.little);
    buf.setUint32(4,  version,     Endian.little);
    buf.setUint32(8,  imageSize,   Endian.little);
    buf.setUint32(12, loadAddress, Endian.little);
    buf.setUint32(16, entryPoint,  Endian.little);
    buf.setUint32(20, kernelSize,  Endian.little);
    buf.setUint32(24, crc32,       Endian.little);
    buf.setUint8 (28, compressed ? 1 : 0);
    // Bytes 29–63: reserved
    return buf.buffer.asUint8List();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ImageBuilder
// ─────────────────────────────────────────────────────────────────────────────

/// Assembles the final bootable kernel image.
///
/// The image layout:
///   [64-byte ImageHeader] [kernel binary] [optional signature]
abstract final class ImageBuilder {
  static final _log = Logger('ImageBuilder');

  /// Build a bootable image from [nativeBinary] and write it to [outputPath].
  ///
  /// Returns the final output path (may differ if `.gz` extension is appended).
  static Future<String> create(
    NativeBinary nativeBinary,
    String outputPath, {
    bool compress             = true,
    PlatformConfig? platform,
    bool writeHeader          = true,
  }) async {
    _log.info('Building image from ${nativeBinary.path}…');

    final cfg = platform ?? PlatformConfig.current;

    // 1. Read the ELF / raw binary
    final binaryBytes = await File(nativeBinary.path).readAsBytes();

    // 2. (Optionally) convert ELF → raw binary (already done in CompilationPipeline)
    final rawBytes = binaryBytes;

    // 3. Compute CRC32
    final crc = CompressionUtils.crc32(rawBytes);

    // 4. Build header
    Uint8List imageBytes;
    if (writeHeader) {
      final header = ImageHeader(
        imageSize:   rawBytes.length + ImageHeader.headerSize,
        loadAddress: cfg.ramBase + 0x8000,
        entryPoint:  cfg.ramBase + 0x8000,
        kernelSize:  rawBytes.length,
        crc32:       crc,
        compressed:  false,
        platform:    cfg,
      );
      imageBytes = Uint8List.fromList([...header.encode(), ...rawBytes]);
    } else {
      imageBytes = rawBytes;
    }

    // 5. Write output
    Directory(p.dirname(outputPath)).createSync(recursive: true);

    if (compress) {
      final compressed = CompressionUtils.compressGzip(imageBytes, level: 9);
      final gzPath     = '$outputPath.gz';
      File(gzPath).writeAsBytesSync(compressed);

      final sizeMb = (compressed.length / (1024 * 1024)).toStringAsFixed(2);
      _log.info('Image written: $gzPath ($sizeMb MB, CRC=0x${crc.toRadixString(16)})');
      return gzPath;
    } else {
      File(outputPath).writeAsBytesSync(imageBytes);
      final sizeMb = (imageBytes.length / (1024 * 1024)).toStringAsFixed(2);
      _log.info('Image written: $outputPath ($sizeMb MB, CRC=0x${crc.toRadixString(16)})');
      return outputPath;
    }
  }

  /// Verify an image file's CRC32 checksum.
  static Future<bool> verify(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();

    Uint8List raw;
    if (imagePath.endsWith('.gz')) {
      raw = Uint8List.fromList(CompressionUtils.decompressGzip(bytes));
    } else {
      raw = bytes;
    }

    if (raw.length < ImageHeader.headerSize) return false;

    final magic = ByteData.sublistView(raw, 0, 4).getUint32(0, Endian.little);
    if (magic != ImageHeader.magic) {
      _log.warning('verify: missing ImageHeader magic');
      return false;
    }

    final storedCrc  = ByteData.sublistView(raw, 24, 28).getUint32(0, Endian.little);
    final kernelData = raw.sublist(ImageHeader.headerSize);
    final actualCrc  = CompressionUtils.crc32(kernelData);

    final ok = storedCrc == actualCrc;
    _log.info('verify: CRC stored=0x${storedCrc.toRadixString(16)} '
        'computed=0x${actualCrc.toRadixString(16)} — ${ok ? 'PASS' : 'FAIL'}');
    return ok;
  }

  /// Print a summary of an image file.
  static Future<void> info(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();

    Uint8List raw;
    if (imagePath.endsWith('.gz')) {
      raw = Uint8List.fromList(CompressionUtils.decompressGzip(bytes));
      _log.info('Image: $imagePath (compressed, expanded to ${raw.length} bytes)');
    } else {
      raw = bytes;
      _log.info('Image: $imagePath (${raw.length} bytes)');
    }

    if (raw.length >= ImageHeader.headerSize) {
      final bd = ByteData.sublistView(raw, 0, ImageHeader.headerSize);
      final magic    = bd.getUint32(0,  Endian.little);
      final ver      = bd.getUint32(4,  Endian.little);
      final size     = bd.getUint32(8,  Endian.little);
      final loadAddr = bd.getUint32(12, Endian.little);
      final entry    = bd.getUint32(16, Endian.little);
      final crc      = bd.getUint32(24, Endian.little);

      if (magic == ImageHeader.magic) {
        _log.info('  Magic   : 0x${magic.toRadixString(16)} (kernel_dart)');
        _log.info('  Version : $ver');
        _log.info('  Size    : $size bytes');
        _log.info('  Load    : 0x${loadAddr.toRadixString(16)}');
        _log.info('  Entry   : 0x${entry.toRadixString(16)}');
        _log.info('  CRC32   : 0x${crc.toRadixString(16)}');
      }
    }

    // Hex dump of first 256 bytes
    _log.fine(HexTools.hexDump(raw.sublist(0, raw.length < 256 ? raw.length : 256)));
  }
}
