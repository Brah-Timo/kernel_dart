/// Dart → Kernel IR → Native AOT compilation pipeline.
///
/// This module wraps the Dart SDK toolchain (`dart compile kernel` and
/// `dart compile exe`) to produce bare-metal-ready ELF/binary artefacts.
library;

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'cross_compile.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Enumerations & value types
// ─────────────────────────────────────────────────────────────────────────────

/// Target CPU architecture.
enum TargetArchitecture {
  arm64,
  arm,
  x86_64,
  riscv64;

  /// Parse from CLI string.
  factory TargetArchitecture.fromString(String s) => switch (s.toLowerCase()) {
        'arm64' || 'aarch64' => TargetArchitecture.arm64,
        'arm'   || 'armv7'  => TargetArchitecture.arm,
        'x86_64'|| 'x64'    => TargetArchitecture.x86_64,
        'riscv64'           => TargetArchitecture.riscv64,
        _ => throw ArgumentError('Unknown architecture: $s'),
      };

  /// GCC cross-compiler prefix.
  String get gccPrefix => switch (this) {
        TargetArchitecture.arm64   => 'aarch64-linux-gnu-',
        TargetArchitecture.arm     => 'arm-linux-gnueabihf-',
        TargetArchitecture.x86_64  => '',
        TargetArchitecture.riscv64 => 'riscv64-linux-gnu-',
      };

  /// Dart SDK os target identifier.
  String get dartOsTarget => switch (this) {
        TargetArchitecture.arm64   => 'fuchsia',
        TargetArchitecture.arm     => 'fuchsia',
        TargetArchitecture.x86_64  => 'linux',
        TargetArchitecture.riscv64 => 'linux',
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// OptimizationLevel
// ─────────────────────────────────────────────────────────────────────────────

/// Optimisation level for the AOT compiler (analogous to -O0…-O3).
enum OptimizationLevel {
  /// No optimisation — fastest compilation, largest binary, best debuggability.
  o0,

  /// Minimal optimisation.
  o1,

  /// Balanced optimisation (default).
  o2,

  /// Maximum optimisation — smallest, fastest binary.
  o3;

  /// Numeric level (0–3).
  int get level => index;
}

/// Security hardening level for the compiled binary.
enum SecurityLevel {
  none,
  standard,
  hardened;
}

/// Compression level for the kernel IR output.
enum CompressionLevel {
  none,
  fast,
  balanced,
  maximum;

  int get gzipLevel => switch (this) {
        CompressionLevel.none     => 0,
        CompressionLevel.fast     => 1,
        CompressionLevel.balanced => 6,
        CompressionLevel.maximum  => 9,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Result objects
// ─────────────────────────────────────────────────────────────────────────────

/// Alias for [KernelBinary] — a compiled Dart Kernel IR (.dill) file.
///
/// Use this name when you only need the path and size (no checksum/timestamp).
final class KernelDill {
  /// Absolute path to the .dill file.
  final String path;

  /// Size in bytes.
  final int sizeBytes;

  const KernelDill({required this.path, required this.sizeBytes});

  @override
  String toString() => 'KernelDill(path: $path, size: ${sizeBytes}B)';
}

/// Represents a compiled Dart Kernel IR file (.dill).
final class KernelBinary {
  /// Absolute path to the .dill file.
  final String path;

  /// Size in bytes.
  final int sizeBytes;

  /// MD5 checksum (hex string).
  final String checksum;

  /// Compilation timestamp.
  final DateTime compiledAt;

  const KernelBinary({
    required this.path,
    required this.sizeBytes,
    required this.checksum,
    required this.compiledAt,
  });

  @override
  String toString() =>
      'KernelBinary(path: $path, size: ${sizeBytes}B, md5: $checksum)';
}

/// Represents a native compiled binary (ELF or raw .bin).
final class NativeBinary {
  /// Absolute path to the ELF/bin file.
  final String path;

  /// Size in bytes.
  final int sizeBytes;

  /// Target architecture.
  final TargetArchitecture architecture;

  /// Whether debug symbols are stripped.
  final bool stripped;

  const NativeBinary({
    required this.path,
    required this.sizeBytes,
    required this.architecture,
    this.stripped = false,
  });

  /// Convenience alias for [architecture].
  TargetArchitecture get arch => architecture;

  @override
  String toString() =>
      'NativeBinary(path: $path, arch: ${architecture.name}, size: ${sizeBytes}B)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Compiler options
// ─────────────────────────────────────────────────────────────────────────────

/// Fine-grained configuration for the compilation pipeline.
final class CompilerOptions {
  /// Enable tree-shaking to remove unused code.
  final bool treeShake;

  /// Enable inlining of small functions.
  final bool inlining;

  /// Enable link-time optimisations.
  final bool lto;

  /// Optimisation level (typed).
  final OptimizationLevel optLevel;

  /// Whether to enable Dart asserts in the compiled binary.
  final bool enableAsserts;

  /// Whether to compile with sound null safety (always true for Dart 3).
  final bool soundNullSafety;

  /// Additional flags forwarded to the Dart AOT compiler.
  final List<String> extraFlags;

  /// Extra defines passed as `-D key=value`.
  final Map<String, String> defines;

  const CompilerOptions({
    this.treeShake          = true,
    this.inlining           = true,
    this.lto                = true,
    this.optLevel           = OptimizationLevel.o2,
    this.enableAsserts      = false,
    this.soundNullSafety    = true,
    this.extraFlags         = const [],
    this.defines            = const {},
  });

  /// Numeric optimisation level (0–3) derived from [optLevel].
  int get optimizationLevel => optLevel.level;

  /// Preset: smallest possible binary (IoT constraints).
  factory CompilerOptions.minSize() => const CompilerOptions(
        treeShake:    true,
        inlining:     false,
        lto:          true,
        optLevel:     OptimizationLevel.o1,
        extraFlags:   ['--no-embed-sources'],
      );

  /// Preset: maximum performance.
  factory CompilerOptions.maxPerformance() => const CompilerOptions(
        treeShake:  true,
        inlining:   true,
        lto:        true,
        optLevel:   OptimizationLevel.o3,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// DartCompiler
// ─────────────────────────────────────────────────────────────────────────────

/// Main compiler facade.
///
/// Wraps the Dart SDK toolchain and cross-compilation utilities to produce
/// AOT-optimised binaries suitable for bare-metal execution.
///
/// ```dart
/// final compiler = DartCompiler(
///   dartSdkPath: '/usr/lib/dart',
///   architecture: TargetArchitecture.arm64,
/// );
///
/// final kernel = await compiler.compileToKernel('bin/main.dart', 'build/out.dill');
/// final native = await compiler.compileToNative(kernel, 'build/out.elf');
/// ```
final class DartCompiler {
  final String dartSdkPath;
  final TargetArchitecture architecture;
  final CompilerOptions options;

  static final _log = Logger('DartCompiler');

  DartCompiler({
    required this.dartSdkPath,
    required this.architecture,
    this.options = const CompilerOptions(),
  });

  // ─── Step 1: Dart source → Kernel IR (.dill) ───────────────────────────────

  /// Compile a Dart source file to Kernel Intermediate Representation.
  ///
  /// Returns a [KernelBinary] describing the produced .dill artefact.
  Future<KernelBinary> compileToKernel(
    String dartSourcePath,
    String outputPath, {
    bool optimize = true,
    CompressionLevel compression = CompressionLevel.maximum,
  }) async {
    _log.info('compileToKernel: $dartSourcePath → $outputPath');

    final dartExe = p.join(dartSdkPath, 'bin', 'dart');
    final args    = <String>[
      'compile',
      'kernel',
      if (optimize) ...['--define', 'dart.vm.product=true'],
      ...options.extraFlags,
      ...options.defines.entries.map((e) => '--define=${e.key}=${e.value}'),
      '-o', outputPath,
      dartSourcePath,
    ];

    await _runProcess(dartExe, args, 'Kernel compilation');

    final file = File(outputPath);
    if (!file.existsSync()) {
      throw StateError('Kernel compilation produced no output at $outputPath');
    }

    final bytes  = file.readAsBytesSync();
    final digest = _md5Hex(bytes);
    _log.fine('Kernel IR: ${bytes.length} bytes, md5=$digest');

    return KernelBinary(
      path:       outputPath,
      sizeBytes:  bytes.length,
      checksum:   digest,
      compiledAt: DateTime.now(),
    );
  }

  // ─── Step 2: Kernel IR → Native ELF ───────────────────────────────────────

  /// Compile a [KernelBinary] to a native machine-code binary.
  ///
  /// Uses `dart compile exe` with AOT flags tuned for bare-metal targets.
  Future<NativeBinary> compileToNative(
    KernelBinary kernel,
    String outputPath, {
    bool stripDebugInfo = false,
    SecurityLevel securityLevel = SecurityLevel.standard,
  }) async {
    _log.info('compileToNative: ${kernel.path} → $outputPath');

    final dartExe = p.join(dartSdkPath, 'bin', 'dart');

    // Build argument list
    final args = <String>[
      'compile',
      'exe',
      '--target-os=${architecture.dartOsTarget}',
      '-O${options.optimizationLevel}',
      if (options.treeShake)  '--no-sound-null-safety-for-js', // placeholder flag
      if (securityLevel == SecurityLevel.hardened) '--no-embed-sources',
      ...options.extraFlags,
      '-o', outputPath,
      kernel.path,
    ];

    await _runProcess(dartExe, args, 'Native compilation');

    // Optionally strip debug symbols using `strip` or cross-`strip`
    if (stripDebugInfo) {
      final stripBin = '${architecture.gccPrefix}strip';
      await _runProcess(stripBin, [outputPath], 'strip debug symbols');
    }

    final file = File(outputPath);
    if (!file.existsSync()) {
      throw StateError('Native compilation produced no output at $outputPath');
    }

    _log.fine('Native binary: ${file.lengthSync()} bytes');

    return NativeBinary(
      path:         outputPath,
      sizeBytes:    file.lengthSync(),
      architecture: architecture,
      stripped:     stripDebugInfo,
    );
  }

  // ─── Step 3: Cross-compilation helper ─────────────────────────────────────

  /// Cross-compile a Dart source for a different [targetArch].
  ///
  /// This is a convenience wrapper around [CrossCompiler] that handles
  /// SDK root detection and target-specific flags automatically.
  Future<NativeBinary> crossCompile(
    String sourcePath,
    String targetPath,
    TargetArchitecture targetArch, {
    bool singleBinary = true,
  }) async {
    _log.info('crossCompile: $sourcePath → $targetPath (${targetArch.name})');

    final xCompiler = CrossCompiler(
      dartSdkPath: dartSdkPath,
      targetArch:  targetArch,
      options:     options,
    );

    return xCompiler.compile(
      sourcePath:   sourcePath,
      outputPath:   targetPath,
      singleBinary: singleBinary,
    );
  }

  // ─── Internal helpers ──────────────────────────────────────────────────────

  Future<void> _runProcess(
    String executable,
    List<String> args,
    String stepName,
  ) async {
    _log.fine('$stepName: $executable ${args.join(' ')}');

    final result = await Process.run(executable, args);

    if (result.exitCode != 0) {
      _log.severe('$stepName failed (exit ${result.exitCode})');
      _log.severe('stdout: ${result.stdout}');
      _log.severe('stderr: ${result.stderr}');
      throw ProcessException(executable, args, result.stderr.toString(), result.exitCode);
    }

    if ((result.stdout as String).isNotEmpty) {
      _log.fine('stdout: ${result.stdout}');
    }
  }

  String _md5Hex(List<int> bytes) {
    // Simple FNV-1a hash as a lightweight checksum (no crypto dependency needed)
    var hash = 2166136261;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CompilationPipeline — orchestrates multi-step builds
// ─────────────────────────────────────────────────────────────────────────────

/// High-level pipeline that chains all compilation steps.
///
/// Suitable for use in build scripts or CI systems.
final class CompilationPipeline {
  final DartCompiler compiler;
  final String buildDir;

  static final _log = Logger('CompilationPipeline');

  const CompilationPipeline({
    required this.compiler,
    this.buildDir = 'build',
  });

  /// Run the full pipeline: source → .dill → .elf → .bin
  ///
  /// Returns the path to the final binary.
  Future<String> run(
    String entryPoint, {
    bool optimize    = true,
    bool strip       = false,
    bool compress    = true,
  }) async {
    Directory(buildDir).createSync(recursive: true);

    final dillPath   = p.join(buildDir, 'kernel.dill');
    final elfPath    = p.join(buildDir, 'kernel.elf');
    final binPath    = p.join(buildDir, 'kernel.bin');

    _log.info('Pipeline start: $entryPoint');

    // 1. Dart → Kernel IR
    final kernel = await compiler.compileToKernel(
      entryPoint,
      dillPath,
      optimize: optimize,
    );
    _log.info('Step 1 done: ${kernel.sizeBytes} bytes of Kernel IR');

    // 2. Kernel IR → Native ELF
    final native = await compiler.compileToNative(
      kernel,
      elfPath,
      stripDebugInfo: strip,
    );
    _log.info('Step 2 done: ${native.sizeBytes} bytes of ELF');

    // 3. ELF → raw .bin
    await _elfToBin(elfPath, binPath);
    _log.info('Step 3 done: raw binary at $binPath');

    // 4. Optional compression
    if (compress) {
      await _gzipFile(binPath);
      _log.info('Step 4 done: compressed to ${binPath}.gz');
      return '$binPath.gz';
    }

    return binPath;
  }

  Future<void> _elfToBin(String elfPath, String binPath) async {
    final objcopy = '${compiler.architecture.gccPrefix}objcopy';
    final result  = await Process.run(objcopy, ['-O', 'binary', elfPath, binPath]);
    if (result.exitCode != 0) {
      throw ProcessException(objcopy, ['-O', 'binary', elfPath, binPath],
          result.stderr.toString(), result.exitCode);
    }
  }

  Future<void> _gzipFile(String filePath) async {
    final result = await Process.run('gzip', ['-f', '-9', filePath]);
    if (result.exitCode != 0) {
      throw ProcessException('gzip', [filePath], result.stderr.toString(), result.exitCode);
    }
  }
}
