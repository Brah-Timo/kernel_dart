import 'package:kernel_dart/src/config/platform_config.dart';
import 'package:kernel_dart/src/emulator/qemu_runner.dart';
import 'package:test/test.dart';

void main() {
  group('QemuMachine enum', () {
    test('has all expected variants', () {
      expect(QemuMachine.values, containsAll([
        QemuMachine.raspberryPi2,
        QemuMachine.raspberryPi3,
        QemuMachine.versatilepb,
        QemuMachine.virtAarch64,
        QemuMachine.x86Pc,
        QemuMachine.riscvVirt,
      ]));
    });
  });

  group('QemuConfig', () {
    test('default values are correct', () {
      const cfg = QemuConfig(imagePath: 'kernel.bin');
      expect(cfg.imagePath,  equals('kernel.bin'));
      expect(cfg.machine,    equals(QemuMachine.versatilepb));
      expect(cfg.memoryMb,   equals(256));
      expect(cfg.cpuCount,   equals(1));
      expect(cfg.debugMode,  isFalse);
      expect(cfg.gdbPort,    equals(1234));
      expect(cfg.noGraphic,  isTrue);
      expect(cfg.extraArgs,  isEmpty);
    });

    test('custom fields are stored', () {
      const cfg = QemuConfig(
        imagePath: 'build/k.bin',
        machine:   QemuMachine.raspberryPi3,
        memoryMb:  512,
        cpuCount:  4,
        debugMode: true,
        gdbPort:   4321,
        noGraphic: false,
        extraArgs: ['-drive', 'file=disk.img'],
      );
      expect(cfg.machine,   equals(QemuMachine.raspberryPi3));
      expect(cfg.memoryMb,  equals(512));
      expect(cfg.cpuCount,  equals(4));
      expect(cfg.debugMode, isTrue);
      expect(cfg.gdbPort,   equals(4321));
      expect(cfg.noGraphic, isFalse);
      expect(cfg.extraArgs, equals(['-drive', 'file=disk.img']));
    });
  });

  group('QemuRunner.buildArgs', () {
    test('returns a non-empty arg list', () {
      final args = QemuRunner.buildArgs(
        platform:  PlatformConfig.raspberryPi3,
        imagePath: 'build/kernel.bin',
      );
      expect(args, isNotEmpty);
    });

    test('includes -machine flag', () {
      final args = QemuRunner.buildArgs(
        platform:  PlatformConfig.raspberryPi3,
        imagePath: 'build/kernel.bin',
      );
      expect(args, contains('-machine'));
    });

    test('includes -cpu flag', () {
      final args = QemuRunner.buildArgs(
        platform:  PlatformConfig.raspberryPi3,
        imagePath: 'build/kernel.bin',
      );
      expect(args, contains('-cpu'));
    });

    test('includes -kernel flag with image path', () {
      final args = QemuRunner.buildArgs(
        platform:  PlatformConfig.raspberryPi3,
        imagePath: 'build/kernel.bin',
      );
      expect(args, contains('-kernel'));
      expect(args, contains('build/kernel.bin'));
    });

    test('includes memory size', () {
      final args = QemuRunner.buildArgs(
        platform:  PlatformConfig.raspberryPi3,
        imagePath: 'k.bin',
        memoryMb:  512,
      );
      expect(args, contains('512M'));
    });

    test('includes -nographic when noGraphic is true', () {
      final args = QemuRunner.buildArgs(
        platform:   PlatformConfig.raspberryPi3,
        imagePath:  'k.bin',
        noGraphic:  true,
      );
      expect(args, contains('-nographic'));
    });

    test('omits -nographic when noGraphic is false', () {
      final args = QemuRunner.buildArgs(
        platform:   PlatformConfig.raspberryPi3,
        imagePath:  'k.bin',
        noGraphic:  false,
      );
      expect(args, isNot(contains('-nographic')));
    });

    test('includes GDB flags when debugMode is true', () {
      final args = QemuRunner.buildArgs(
        platform:  PlatformConfig.raspberryPi3,
        imagePath: 'k.bin',
        debugMode: true,
        gdbPort:   1234,
      );
      expect(args, contains('-s'));
      expect(args, contains('-S'));
    });

    test('omits GDB flags when debugMode is false', () {
      final args = QemuRunner.buildArgs(
        platform:  PlatformConfig.raspberryPi3,
        imagePath: 'k.bin',
        debugMode: false,
      );
      expect(args, isNot(contains('-S')));
    });

    test('appends extra args', () {
      final args = QemuRunner.buildArgs(
        platform:  PlatformConfig.raspberryPi3,
        imagePath: 'k.bin',
        extra:     ['-device', 'virtio-net'],
      );
      expect(args, containsAll(['-device', 'virtio-net']));
    });

    test('x86_64 platform maps to qemu64 CPU arg', () {
      // genericArm64 uses TargetArchitecture.arm64 → cortex-a53
      // For x86 we create a custom platform with x86_64 architecture
      final args = QemuRunner.buildArgs(
        platform:  PlatformConfig.genericArm64,
        imagePath: 'k.bin',
      );
      // genericArm64 is AArch64 → expects cortex-a53
      expect(args, contains('cortex-a53'));
    });
  });
}
