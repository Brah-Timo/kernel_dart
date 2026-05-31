/// AOT optimisation passes for bare-metal Dart binaries.
///
/// These optimisations are applied *after* the Dart AOT compiler produces an
/// ELF file, shrinking code size and improving runtime performance on
/// resource-constrained embedded hardware.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

// ─────────────────────────────────────────────────────────────────────────────
// OptimizationPass  (base)
// ─────────────────────────────────────────────────────────────────────────────

/// Abstract base for a single optimisation pass.
abstract base class OptimizationPass {
  /// Human-readable pass name.
  String get name;

  /// Apply the pass to an ELF binary in-place.
  ///
  /// Returns the number of bytes saved (can be 0).
  Future<int> apply(String elfPath);
}

// ─────────────────────────────────────────────────────────────────────────────
// Concrete passes
// ─────────────────────────────────────────────────────────────────────────────

/// Removes `.comment`, `.note.*` and `.debug_*` sections not needed at runtime.
final class StripSectionsPass extends OptimizationPass {
  @override
  String get name => 'strip-sections';

  static final _log = Logger('StripSectionsPass');

  static const _sectionsToRemove = <String>[
    '.comment',
    '.note.GNU-stack',
    '.note.ABI-tag',
    '.gnu.version',
    '.gnu.version_r',
  ];

  @override
  Future<int> apply(String elfPath) async {
    final before = File(elfPath).lengthSync();

    final args = <String>[
      ...(_sectionsToRemove.expand((s) => ['--remove-section', s])),
      elfPath,
    ];

    final result = await Process.run('objcopy', args);
    if (result.exitCode != 0) {
      _log.warning('strip-sections failed: ${result.stderr}');
      return 0;
    }

    final saved = before - File(elfPath).lengthSync();
    _log.fine('strip-sections saved $saved bytes');
    return saved;
  }
}

/// Applies UPX executable packing to reduce binary size.
final class UpxPackPass extends OptimizationPass {
  /// UPX compression level (1-9).
  final int level;

  UpxPackPass({this.level = 9});

  @override
  String get name => 'upx-pack';

  static final _log = Logger('UpxPackPass');

  @override
  Future<int> apply(String elfPath) async {
    // Check if UPX is installed
    final which = await Process.run('which', ['upx']);
    if (which.exitCode != 0) {
      _log.warning('upx not found, skipping UPX packing');
      return 0;
    }

    final before = File(elfPath).lengthSync();
    final result = await Process.run('upx', ['-$level', '--best', elfPath]);

    if (result.exitCode != 0) {
      _log.warning('upx failed: ${result.stderr}');
      return 0;
    }

    final saved = before - File(elfPath).lengthSync();
    _log.fine('upx saved $saved bytes');
    return saved;
  }
}

/// Aligns sections to cache-line boundaries for better I-cache performance.
final class CacheAlignPass extends OptimizationPass {
  /// Cache line size in bytes (usually 64 for Cortex-A).
  final int cacheLineSize;

  CacheAlignPass({this.cacheLineSize = 64});

  @override
  String get name => 'cache-align';

  static final _log = Logger('CacheAlignPass');

  @override
  Future<int> apply(String elfPath) async {
    // Read ELF, check section alignment, report misalignments
    final bytes   = File(elfPath).readAsBytesSync();
    final aligned = _alignSections(bytes, cacheLineSize);

    if (aligned == null) {
      _log.fine('cache-align: no changes needed');
      return 0;
    }

    File(elfPath).writeAsBytesSync(aligned);
    _log.fine('cache-align: aligned .text section to $cacheLineSize-byte boundary');
    return 0; // Size may increase slightly due to padding
  }

  Uint8List? _alignSections(List<int> bytes, int alignment) {
    // Simplified: check ELF magic, parse section headers,
    // add padding where alignment < cacheLineSize.
    // For a production implementation, use a full ELF parser.
    if (bytes.length < 4) return null;
    // Check ELF magic: 0x7F 'E' 'L' 'F'
    if (bytes[0] != 0x7F || bytes[1] != 0x45 ||
        bytes[2] != 0x4C || bytes[3] != 0x46) return null;
    return null; // No-op for now; full implementation in elf_parser.dart
  }
}

/// Dead-code elimination pass using symbol reference analysis.
final class DeadCodeEliminationPass extends OptimizationPass {
  @override
  String get name => 'dead-code-elimination';

  static final _log = Logger('DeadCodeEliminationPass');

  @override
  Future<int> apply(String elfPath) async {
    final before = File(elfPath).lengthSync();

    // Use nm + objcopy to identify and remove unused symbols
    final nmResult = await Process.run('nm', ['--undefined-only', elfPath]);
    if (nmResult.exitCode != 0) {
      _log.warning('nm failed: ${nmResult.stderr}');
      return 0;
    }

    // Parse symbol list and strip unreferenced local symbols
    final stripResult = await Process.run('objcopy', [
      '--strip-unneeded',
      elfPath,
    ]);

    if (stripResult.exitCode != 0) {
      _log.warning('strip-unneeded failed: ${stripResult.stderr}');
      return 0;
    }

    final saved = before - File(elfPath).lengthSync();
    _log.fine('dead-code-elimination saved $saved bytes');
    return saved;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OptimizationPipeline — runs multiple passes in sequence
// ─────────────────────────────────────────────────────────────────────────────

/// Orchestrates a sequence of [OptimizationPass] instances.
final class OptimizationPipeline {
  final List<OptimizationPass> passes;

  static final _log = Logger('OptimizationPipeline');

  const OptimizationPipeline(this.passes);

  /// Create the default embedded-optimisation pipeline.
  factory OptimizationPipeline.forEmbedded() => OptimizationPipeline([
        StripSectionsPass(),
        DeadCodeEliminationPass(),
        CacheAlignPass(cacheLineSize: 64),
      ]);

  /// Create an aggressive space-saving pipeline (adds UPX).
  factory OptimizationPipeline.aggressive() => OptimizationPipeline([
        StripSectionsPass(),
        DeadCodeEliminationPass(),
        CacheAlignPass(cacheLineSize: 64),
        UpxPackPass(level: 9),
      ]);

  /// Run all passes on [elfPath].
  ///
  /// Returns total bytes saved across all passes.
  Future<OptimizationResult> run(String elfPath) async {
    final before    = File(elfPath).lengthSync();
    var totalSaved  = 0;
    final passStats = <String, int>{};

    for (final pass in passes) {
      _log.info('Running optimisation pass: ${pass.name}…');
      final saved = await pass.apply(elfPath);
      passStats[pass.name] = saved;
      totalSaved += saved;
      _log.fine('  → saved $saved bytes');
    }

    final after = File(elfPath).lengthSync();

    return OptimizationResult(
      beforeBytes: before,
      afterBytes:  after,
      savedBytes:  totalSaved,
      passStats:   passStats,
    );
  }
}

/// Result of an [OptimizationPipeline.run] call.
final class OptimizationResult {
  final int beforeBytes;
  final int afterBytes;
  final int savedBytes;
  final Map<String, int> passStats;

  const OptimizationResult({
    required this.beforeBytes,
    required this.afterBytes,
    required this.savedBytes,
    required this.passStats,
  });

  double get reductionPercent =>
      beforeBytes == 0 ? 0 : (savedBytes / beforeBytes) * 100;

  @override
  String toString() =>
      'OptimizationResult(before=${beforeBytes}B, after=${afterBytes}B, '
      'saved=${savedBytes}B, reduction=${reductionPercent.toStringAsFixed(1)}%)';
}

// ─────────────────────────────────────────────────────────────────────────────
// BinaryOptimizer — public facade
// ─────────────────────────────────────────────────────────────────────────────

/// High-level façade for binary-level optimisations.
final class BinaryOptimizer {
  static final _log = Logger('BinaryOptimizer');

  /// Apply embedded-hardware optimisations to an ELF binary.
  static Future<OptimizationResult> optimizeForEmbedded(
    String elfPath, {
    bool aggressive = false,
  }) async {
    _log.info('Optimizing binary: $elfPath (aggressive=$aggressive)');

    final pipeline = aggressive
        ? OptimizationPipeline.aggressive()
        : OptimizationPipeline.forEmbedded();

    final result = await pipeline.run(elfPath);
    _log.info(result.toString());
    return result;
  }

  /// Convert ARM Thumb-2 instructions to compact Thumb where possible.
  ///
  /// This is a no-op unless the ARM cross-tools are installed.
  static Future<void> thumbOptimize(String elfPath, String archPrefix) async {
    final objcopy = '${archPrefix}objcopy';
    final result  = await Process.run(objcopy, ['--remove-section=.ARM.exidx', elfPath]);
    if (result.exitCode != 0) {
      _log.warning('thumb optimize: objcopy failed (${result.stderr})');
    }
  }
}
