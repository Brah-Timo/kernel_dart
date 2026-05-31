/// Cross-compilation support for targeting architectures different from the host.
///
/// Wraps GCC cross-toolchains and Dart SDK cross-compilation capabilities to
/// produce bare-metal binaries for ARM64, ARM32, x86-64 and RISC-V targets.
library;

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'dart_compiler.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CrossToolchain
// ─────────────────────────────────────────────────────────────────────────────

/// Describes the native tools available for a cross-compilation target.
final class CrossToolchain {
  final TargetArchitecture architecture;

  /// Full path (or name on PATH) of the C compiler.
  final String cc;

  /// Full path (or name on PATH) of the assembler.
  final String as;

  /// Full path (or name on PATH) of the linker.
  final String ld;

  /// Full path (or name on PATH) of objcopy.
  final String objcopy;

  /// Full path (or name on PATH) of the strip utility.
  final String strip;

  /// Additional compiler flags.
  final List<String> cflags;

  const CrossToolchain({
    required this.architecture,
    required this.cc,
    required this.as,
    required this.ld,
    required this.objcopy,
    required this.strip,
    this.cflags = const [],
  });

  // ─── Factory constructors for known architectures ──────────────────────────

  factory CrossToolchain.arm64() => const CrossToolchain(
        architecture: TargetArchitecture.arm64,
        cc:      'aarch64-linux-gnu-gcc',
        as:      'aarch64-linux-gnu-as',
        ld:      'aarch64-linux-gnu-ld',
        objcopy: 'aarch64-linux-gnu-objcopy',
        strip:   'aarch64-linux-gnu-strip',
        cflags: ['-mcpu=cortex-a72', '-mabi=lp64', '-ffreestanding', '-fno-pie', '-fno-stack-protector'],
      );

  factory CrossToolchain.arm() => const CrossToolchain(
        architecture: TargetArchitecture.arm,
        cc:      'arm-linux-gnueabihf-gcc',
        as:      'arm-linux-gnueabihf-as',
        ld:      'arm-linux-gnueabihf-ld',
        objcopy: 'arm-linux-gnueabihf-objcopy',
        strip:   'arm-linux-gnueabihf-strip',
        cflags: ['-mcpu=cortex-a7', '-mfpu=neon-vfpv4', '-mfloat-abi=hard', '-ffreestanding', '-fno-pie'],
      );

  factory CrossToolchain.x86_64() => const CrossToolchain(
        architecture: TargetArchitecture.x86_64,
        cc:      'gcc',
        as:      'as',
        ld:      'ld',
        objcopy: 'objcopy',
        strip:   'strip',
        cflags: ['-m64', '-ffreestanding', '-fno-pie', '-fno-stack-protector'],
      );

  factory CrossToolchain.riscv64() => const CrossToolchain(
        architecture: TargetArchitecture.riscv64,
        cc:      'riscv64-linux-gnu-gcc',
        as:      'riscv64-linux-gnu-as',
        ld:      'riscv64-linux-gnu-ld',
        objcopy: 'riscv64-linux-gnu-objcopy',
        strip:   'riscv64-linux-gnu-strip',
        cflags: ['-march=rv64gc', '-mabi=lp64d', '-ffreestanding', '-fno-pie'],
      );

  /// Auto-select toolchain for the given architecture.
  factory CrossToolchain.forArch(TargetArchitecture arch) => switch (arch) {
        TargetArchitecture.arm64   => CrossToolchain.arm64(),
        TargetArchitecture.arm     => CrossToolchain.arm(),
        TargetArchitecture.x86_64  => CrossToolchain.x86_64(),
        TargetArchitecture.riscv64 => CrossToolchain.riscv64(),
      };

  // ─── Toolchain validation ──────────────────────────────────────────────────

  /// Verify that all toolchain executables exist on the system PATH.
  Future<ToolchainCheckResult> verify() async {
    final missing = <String>[];

    for (final tool in [cc, as, ld, objcopy, strip]) {
      final result = await Process.run('which', [tool]);
      if (result.exitCode != 0) missing.add(tool);
    }

    return ToolchainCheckResult(
      architecture: architecture,
      missing:      missing,
      isComplete:   missing.isEmpty,
    );
  }
}

/// Result of a toolchain availability check.
final class ToolchainCheckResult {
  final TargetArchitecture architecture;
  final List<String> missing;
  final bool isComplete;

  const ToolchainCheckResult({
    required this.architecture,
    required this.missing,
    required this.isComplete,
  });

  @override
  String toString() => isComplete
      ? 'ToolchainCheckResult(${architecture.name}: OK)'
      : 'ToolchainCheckResult(${architecture.name}: MISSING ${missing.join(', ')})';
}

// ─────────────────────────────────────────────────────────────────────────────
// CrossCompiler
// ─────────────────────────────────────────────────────────────────────────────

/// Compiles a Dart project for a target architecture different from the host.
///
/// Uses the Dart SDK's cross-compilation support together with a native
/// cross-toolchain for linking C/Assembly startup code.
final class CrossCompiler {
  final String dartSdkPath;
  final TargetArchitecture targetArch;
  final CompilerOptions options;
  late final CrossToolchain toolchain;

  static final _log = Logger('CrossCompiler');

  CrossCompiler({
    required this.dartSdkPath,
    required this.targetArch,
    this.options = const CompilerOptions(),
  }) {
    toolchain = CrossToolchain.forArch(targetArch);
  }

  // ─── Main compile entry ────────────────────────────────────────────────────

  /// Compile [sourcePath] to a native binary at [outputPath].
  Future<NativeBinary> compile({
    required String sourcePath,
    required String outputPath,
    bool singleBinary = true,
    String? linkerScript,
  }) async {
    _log.info('CrossCompile ${targetArch.name}: $sourcePath → $outputPath');

    // 1. Verify toolchain
    final check = await toolchain.verify();
    if (!check.isComplete) {
      throw StateError(
        'Cross-toolchain for ${targetArch.name} is incomplete. '
        'Missing: ${check.missing.join(', ')}',
      );
    }

    // 2. Compile Dart → Kernel IR
    final dartCompiler = DartCompiler(
      dartSdkPath:  dartSdkPath,
      architecture: targetArch,
      options:      options,
    );

    final buildDir = p.dirname(outputPath);
    Directory(buildDir).createSync(recursive: true);

    final dillPath = p.join(buildDir, 'kernel_${targetArch.name}.dill');
    final elfPath  = p.join(buildDir, 'kernel_${targetArch.name}.elf');

    final kernel = await dartCompiler.compileToKernel(sourcePath, dillPath);
    await dartCompiler.compileToNative(kernel, elfPath);

    // 3. Re-link with the cross-linker if a linker script is provided
    if (linkerScript != null) {
      await _relink(elfPath, outputPath, linkerScript);
    } else {
      File(elfPath).copySync(outputPath);
    }

    final file = File(outputPath);
    _log.info('Cross-compilation done: ${file.lengthSync()} bytes');

    return NativeBinary(
      path:         outputPath,
      sizeBytes:    file.lengthSync(),
      architecture: targetArch,
    );
  }

  // ─── Compile C/Assembly files ──────────────────────────────────────────────

  /// Compile a C source file to an object file using the cross-toolchain.
  Future<String> compileC(
    String sourcePath,
    String outputObjPath, {
    List<String> extraFlags = const [],
  }) async {
    _log.fine('Compiling C: $sourcePath');

    final args = <String>[
      '-c',
      ...toolchain.cflags,
      ...extraFlags,
      '-o', outputObjPath,
      sourcePath,
    ];

    await _runProcess(toolchain.cc, args, 'C compilation of $sourcePath');
    return outputObjPath;
  }

  /// Assemble an Assembly (.S) source file to an object file.
  Future<String> assembleS(
    String sourcePath,
    String outputObjPath, {
    List<String> extraFlags = const [],
  }) async {
    _log.fine('Assembling: $sourcePath');

    final args = <String>[
      ...extraFlags,
      '-o', outputObjPath,
      sourcePath,
    ];

    await _runProcess(toolchain.as, args, 'Assembly of $sourcePath');
    return outputObjPath;
  }

  /// Link multiple object files into a final ELF.
  Future<String> link(
    List<String> objectFiles,
    String outputElfPath, {
    required String linkerScript,
    List<String> extraFlags = const [],
  }) async {
    _log.fine('Linking ${objectFiles.length} objects → $outputElfPath');

    final args = <String>[
      '-T', linkerScript,
      ...extraFlags,
      '-o', outputElfPath,
      ...objectFiles,
    ];

    await _runProcess(toolchain.ld, args, 'Linking');
    return outputElfPath;
  }

  // ─── Internal helpers ──────────────────────────────────────────────────────

  Future<void> _relink(
    String elfPath,
    String outputPath,
    String linkerScript,
  ) async {
    final args = <String>[
      '-T', linkerScript,
      '-o', outputPath,
      elfPath,
    ];
    await _runProcess(toolchain.ld, args, 'Re-linking with custom linker script');
  }

  Future<void> _runProcess(
    String executable,
    List<String> args,
    String stepName,
  ) async {
    final result = await Process.run(executable, args);

    if (result.exitCode != 0) {
      _log.severe('$stepName failed: ${result.stderr}');
      throw ProcessException(executable, args, result.stderr.toString(), result.exitCode);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CrossBuildPipeline — high-level, multi-arch batch builder
// ─────────────────────────────────────────────────────────────────────────────

/// Builds for multiple target architectures in parallel or sequentially.
final class CrossBuildPipeline {
  final String dartSdkPath;
  final String sourcePath;
  final String outputDir;
  final CompilerOptions options;

  static final _log = Logger('CrossBuildPipeline');

  const CrossBuildPipeline({
    required this.dartSdkPath,
    required this.sourcePath,
    required this.outputDir,
    this.options = const CompilerOptions(),
  });

  /// Build for all [targets] sequentially.
  Future<List<NativeBinary>> buildAll(
    List<TargetArchitecture> targets,
  ) async {
    final results = <NativeBinary>[];

    for (final arch in targets) {
      _log.info('Building for ${arch.name}…');

      final xc = CrossCompiler(
        dartSdkPath: dartSdkPath,
        targetArch:  arch,
        options:     options,
      );

      final outPath = p.join(outputDir, 'kernel_${arch.name}.elf');
      final binary  = await xc.compile(
        sourcePath: sourcePath,
        outputPath: outPath,
      );
      results.add(binary);

      _log.info('  → ${binary.sizeBytes} bytes');
    }

    return results;
  }
}
