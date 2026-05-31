import 'dart:io';

import 'package:kernel_dart/src/bootloader/bootloader_arm.dart';
import 'package:test/test.dart';

void main() {
  group('TargetBoard enum', () {
    test('raspberryPi3 has correct fields', () {
      const b = TargetBoard.raspberryPi3;
      expect(b.name,       equals('Raspberry Pi 3'));
      expect(b.uartBase,   equals(0x3F201000));
      expect(b.gpioBase,   equals(0x3F200000));
      expect(b.kernelLoad, equals(0x00080000));
    });

    test('raspberryPi4 has correct fields', () {
      const b = TargetBoard.raspberryPi4;
      expect(b.uartBase, equals(0xFE201000));
      expect(b.gpioBase, equals(0xFE200000));
    });

    test('all boards have non-zero ramSize', () {
      for (final board in TargetBoard.values) {
        expect(board.ramSize, greaterThan(0));
      }
    });
  });

  group('ARMBootloader — AArch64', () {
    late ARMBootloader bl;

    setUp(() {
      bl = ARMBootloader(
        targetBoard: TargetBoard.raspberryPi3,
        aarch64:     true,
      );
    });

    test('generateBootloaderAsm returns non-empty string', () {
      expect(bl.generateBootloaderAsm(), isNotEmpty);
    });

    test('generated ASM contains _start entry point', () {
      expect(bl.generateBootloaderAsm(), contains('_start'));
    });

    test('generated ASM contains UART base address', () {
      // The ASM uses lowercase hex: 0x3f201000
      final asm = bl.generateBootloaderAsm();
      expect(
        asm.toLowerCase(),
        contains('3f201000'),
      );
    });

    test('generated ASM contains kernel entry branch', () {
      // The bootloader branches to the kernel load address (0x80000)
      expect(bl.generateBootloaderAsm(), contains('0x80000'));
    });

    test('generated ASM disables interrupts (DAIFSet)', () {
      expect(bl.generateBootloaderAsm(), contains('DAIFSet'));
    });

    test('generateLinkerScript returns non-empty string', () {
      expect(bl.generateLinkerScript(), isNotEmpty);
    });

    test('linker script contains kernel load address', () {
      // Default load address for Pi 3 is 0x80000
      expect(bl.generateLinkerScript(), contains('0x80000'));
    });

    test('linker script contains ENTRY directive', () {
      expect(bl.generateLinkerScript(), contains('ENTRY'));
    });

    test('linker script has OUTPUT_ARCH(aarch64)', () {
      expect(bl.generateLinkerScript(), contains('aarch64'));
    });
  });

  group('ARMBootloader — ARMv7-A 32-bit', () {
    test('generates ARM32 assembly when aarch64=false', () {
      final bl = ARMBootloader(
        targetBoard: TargetBoard.genericArm32,
        aarch64:     false,
      );
      final asm = bl.generateBootloaderAsm();
      expect(asm, isNotEmpty);
      expect(asm, contains('_start'));
    });
  });

  group('ARMBootloader.writeFiles', () {
    test('creates .S and .ld files in the output directory', () async {
      final dir = Directory.systemTemp.createTempSync('arm_bl_test_');
      try {
        final bl = ARMBootloader(targetBoard: TargetBoard.raspberryPi3);
        await bl.writeFiles(dir.path);

        final files = dir.listSync().map((e) => e.path).toList();
        expect(files.any((f) => f.endsWith('.S')),  isTrue, reason: '.S file not created');
        expect(files.any((f) => f.endsWith('.ld')), isTrue, reason: '.ld file not created');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('ARMBootloader custom addresses', () {
    test('custom kernelLoadAddress appears in linker script', () {
      final bl = ARMBootloader(
        targetBoard:       TargetBoard.raspberryPi3,
        kernelLoadAddress: 0x100000,
      );
      expect(bl.generateLinkerScript(), contains('100000'));
    });
  });
}
