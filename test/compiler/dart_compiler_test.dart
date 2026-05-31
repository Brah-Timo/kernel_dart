import 'package:kernel_dart/src/compiler/dart_compiler.dart';
import 'package:kernel_dart/src/compiler/cross_compile.dart';
import 'package:test/test.dart';

void main() {
  group('TargetArchitecture enum', () {
    test('has arm64, arm, x86_64, riscv64', () {
      expect(TargetArchitecture.values, containsAll([
        TargetArchitecture.arm64,
        TargetArchitecture.arm,
        TargetArchitecture.x86_64,
        TargetArchitecture.riscv64,
      ]));
    });

    test('names are correct', () {
      expect(TargetArchitecture.arm64.name,   equals('arm64'));
      expect(TargetArchitecture.x86_64.name,  equals('x86_64'));
      expect(TargetArchitecture.riscv64.name, equals('riscv64'));
    });
  });

  group('OptimizationLevel enum', () {
    test('has o0 through o3', () {
      expect(OptimizationLevel.values.length, equals(4));
      expect(OptimizationLevel.values, containsAll([
        OptimizationLevel.o0,
        OptimizationLevel.o1,
        OptimizationLevel.o2,
        OptimizationLevel.o3,
      ]));
    });
  });

  group('CompilerOptions', () {
    test('default options are conservative', () {
      const opts = CompilerOptions();
      expect(opts.enableAsserts,   isFalse);
      expect(opts.soundNullSafety, isTrue);
      expect(opts.optLevel,        equals(OptimizationLevel.o2));
    });

    test('custom options are stored correctly', () {
      const opts = CompilerOptions(
        enableAsserts:   true,
        soundNullSafety: false,
        optLevel:        OptimizationLevel.o3,
        extraFlags:      ['-DDEBUG'],
      );
      expect(opts.enableAsserts,   isTrue);
      expect(opts.soundNullSafety, isFalse);
      expect(opts.optLevel,        equals(OptimizationLevel.o3));
      expect(opts.extraFlags,      equals(['-DDEBUG']));
    });
  });

  group('KernelDill', () {
    test('stores path and size', () {
      const dill = KernelDill(path: 'build/k.dill', sizeBytes: 1024 * 512);
      expect(dill.path,      equals('build/k.dill'));
      expect(dill.sizeBytes, equals(1024 * 512));
    });
  });

  group('NativeBinary', () {
    test('stores path, arch, and size', () {
      const bin = NativeBinary(
        path:         'build/k.elf',
        architecture: TargetArchitecture.arm64,
        sizeBytes:    2 * 1024 * 1024,
      );
      expect(bin.path,      equals('build/k.elf'));
      expect(bin.arch,      equals(TargetArchitecture.arm64));
      expect(bin.sizeBytes, equals(2 * 1024 * 1024));
    });
  });

  group('DartCompiler construction', () {
    test('creates with dart SDK path and architecture', () {
      final compiler = DartCompiler(
        dartSdkPath:  '/usr/lib/dart',
        architecture: TargetArchitecture.arm64,
      );
      expect(compiler, isNotNull);
    });

    test('uses default CompilerOptions when not provided', () {
      final compiler = DartCompiler(
        dartSdkPath:  '/usr/lib/dart',
        architecture: TargetArchitecture.x86_64,
      );
      expect(compiler.options.optLevel, equals(OptimizationLevel.o2));
    });

    test('stores custom options', () {
      final compiler = DartCompiler(
        dartSdkPath:  '/usr/lib/dart',
        architecture: TargetArchitecture.arm64,
        options: const CompilerOptions(optLevel: OptimizationLevel.o0),
      );
      expect(compiler.options.optLevel, equals(OptimizationLevel.o0));
    });
  });

  group('CrossToolchain', () {
    test('arm64 toolchain has correct prefix', () {
      final tc = CrossToolchain.arm64();
      expect(tc.cc, contains('aarch64'));
    });

    test('arm toolchain has correct prefix', () {
      final tc = CrossToolchain.arm();
      expect(tc.cc, contains('arm-linux-gnueabihf'));
    });

    test('x86_64 toolchain uses native gcc', () {
      final tc = CrossToolchain.x86_64();
      expect(tc.cc, equals('gcc'));
    });

    test('riscv64 toolchain has correct prefix', () {
      final tc = CrossToolchain.riscv64();
      expect(tc.cc, contains('riscv64'));
    });

    test('forArch selects the right toolchain', () {
      expect(CrossToolchain.forArch(TargetArchitecture.arm64).cc,
          contains('aarch64'));
      expect(CrossToolchain.forArch(TargetArchitecture.x86_64).cc,
          equals('gcc'));
    });
  });

  group('ToolchainCheckResult', () {
    test('isComplete is true when missing is empty', () {
      const result = ToolchainCheckResult(
        architecture: TargetArchitecture.arm64,
        missing:      [],
        isComplete:   true,
      );
      expect(result.isComplete, isTrue);
      expect(result.missing,    isEmpty);
    });

    test('toString mentions architecture', () {
      const result = ToolchainCheckResult(
        architecture: TargetArchitecture.x86_64,
        missing:      [],
        isComplete:   true,
      );
      expect(result.toString(), contains('x86_64'));
    });
  });
}
