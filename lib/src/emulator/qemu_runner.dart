/// QEMU emulator runner.
///
/// Builds QEMU command-line arguments for running a kernel_dart image in the
/// QEMU system emulator. Supports ARM, AArch64, x86-64 and RISC-V targets.
library;

import 'dart:io';
import 'package:logging/logging.dart';

import '../compiler/dart_compiler.dart';
import '../config/platform_config.dart';

// ─────────────────────────────────────────────────────────────────────────────
// QemuMachine
// ─────────────────────────────────────────────────────────────────────────────

/// QEMU machine types.
enum QemuMachine {
  /// ARM Versatile PB (QEMU: versatilepb)
  versatilepb,

  /// ARM Cortex-A7 Raspberry Pi 2 (QEMU: raspi2b)
  raspberryPi2,

  /// ARM Cortex-A53 Raspberry Pi 3 (QEMU: raspi3b)
  raspberryPi3,

  /// AArch64 generic virtual machine (QEMU: virt)
  virtAarch64,

  /// x86-64 generic PC (QEMU: pc or q35)
  x86Pc,

  /// RISC-V 64-bit virtual machine (QEMU: virt)
  riscvVirt,
}

// ─────────────────────────────────────────────────────────────────────────────
// QemuConfig
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for a QEMU run.
final class QemuConfig {
  final String imagePath;
  final QemuMachine machine;
  final int memoryMb;
  final int cpuCount;
  final bool debugMode;
  final int gdbPort;
  final bool noGraphic;
  final List<String> extraArgs;

  const QemuConfig({
    required this.imagePath,
    this.machine    = QemuMachine.versatilepb,
    this.memoryMb   = 256,
    this.cpuCount   = 1,
    this.debugMode  = false,
    this.gdbPort    = 1234,
    this.noGraphic  = true,
    this.extraArgs  = const [],
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// QemuRunner
// ─────────────────────────────────────────────────────────────────────────────

/// Utility for launching QEMU with a kernel_dart image.
///
/// ```dart
/// final args = QemuRunner.buildArgs(
///   platform:  PlatformConfig.raspberryPi3,
///   imagePath: 'build/kernel.bin',
///   memoryMb:  512,
/// );
/// final result = await Process.run('qemu-system-aarch64', args);
/// ```
abstract final class QemuRunner {
  static final _log = Logger('QemuRunner');

  // ─── Argument builder ─────────────────────────────────────────────────────

  /// Build QEMU command-line arguments for [platform] and [imagePath].
  ///
  /// Parameters:
  /// - [platform]   The target hardware config.
  /// - [imagePath]  Path to the kernel image (ELF or binary).
  /// - [memoryMb]   RAM in MB (default 256).
  /// - [cpuCount]   Number of vCPUs (default 1).
  /// - [debugMode]  If true, adds `-s -S` for GDB remote debugging.
  /// - [gdbPort]    GDB port (default 1234).  Only used when [debugMode] is true.
  /// - [noGraphic]  If true, adds `-nographic`.
  /// - [extra]      Additional raw QEMU arguments.
  static List<String> buildArgs({
    required PlatformConfig platform,
    required String imagePath,
    int memoryMb      = 256,
    int cpuCount      = 1,
    bool debugMode    = false,
    int gdbPort       = 1234,
    bool noGraphic    = true,
    List<String> extra = const [],
  }) {
    final args = <String>[];

    // -machine
    final machineStr = _machineFor(platform);
    args.addAll(['-machine', machineStr]);

    // -cpu
    final cpuStr = _cpuFor(platform);
    args.addAll(['-cpu', cpuStr]);

    // -m (memory)
    args.addAll(['-m', '${memoryMb}M']);

    // -smp (CPU count)
    if (cpuCount > 1) {
      args.addAll(['-smp', '$cpuCount']);
    }

    // -kernel
    args.addAll(['-kernel', imagePath]);

    // -serial (route serial → stdio)
    args.addAll(['-serial', 'stdio']);

    // -nographic
    if (noGraphic) args.add('-nographic');

    // GDB stub
    if (debugMode) {
      args.addAll(['-s', '-S']);
      _log.info('Debug mode: GDB stub on port $gdbPort');
    }

    // Extra args
    args.addAll(extra);

    _log.fine('QEMU args: ${args.join(' ')}');
    return args;
  }

  // ─── Launch ───────────────────────────────────────────────────────────────

  /// Run QEMU synchronously (blocking) with [config].
  ///
  /// Returns the exit code of the QEMU process.
  static Future<int> run(QemuConfig config) async {
    final binary = _qemuBinaryFor(config.machine);
    final args   = buildArgs(
      platform:   _platformForMachine(config.machine),
      imagePath:  config.imagePath,
      memoryMb:   config.memoryMb,
      cpuCount:   config.cpuCount,
      debugMode:  config.debugMode,
      gdbPort:    config.gdbPort,
      noGraphic:  config.noGraphic,
      extra:      config.extraArgs,
    );

    _log.info('Launching: $binary ${args.join(' ')}');
    final process = await Process.start(binary, args,
        mode: ProcessStartMode.inheritStdio);
    return process.exitCode;
  }

  // ─── Internal helpers ─────────────────────────────────────────────────────

  static String _machineFor(PlatformConfig p) => switch (p.architecture) {
        TargetArchitecture.arm64   => 'virt',
        TargetArchitecture.arm     => 'versatilepb',
        TargetArchitecture.x86_64  => 'q35',
        TargetArchitecture.riscv64 => 'virt',
      };

  static String _cpuFor(PlatformConfig p) => switch (p.architecture) {
        TargetArchitecture.arm64   => 'cortex-a53',
        TargetArchitecture.arm     => 'cortex-a7',
        TargetArchitecture.x86_64  => 'qemu64',
        TargetArchitecture.riscv64 => 'rv64',
      };

  static String _qemuBinaryFor(QemuMachine m) => switch (m) {
        QemuMachine.versatilepb ||
        QemuMachine.raspberryPi2 ||
        QemuMachine.raspberryPi3  => 'qemu-system-aarch64',
        QemuMachine.virtAarch64   => 'qemu-system-aarch64',
        QemuMachine.x86Pc         => 'qemu-system-x86_64',
        QemuMachine.riscvVirt     => 'qemu-system-riscv64',
      };

  static PlatformConfig _platformForMachine(QemuMachine m) => switch (m) {
        QemuMachine.raspberryPi2  => PlatformConfig.raspberryPi3,
        QemuMachine.raspberryPi3  => PlatformConfig.raspberryPi3,
        QemuMachine.versatilepb   => PlatformConfig.genericArm64,
        QemuMachine.virtAarch64   => PlatformConfig.genericArm64,
        QemuMachine.x86Pc         => PlatformConfig.genericArm64, // closest available
        QemuMachine.riscvVirt     => PlatformConfig.genericArm64,
      };
}
