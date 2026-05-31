import 'dart:io';

import 'package:kernel_dart/src/bootloader/bootloader_x86.dart';
import 'package:test/test.dart';

void main() {
  group('X86BootMode enum', () {
    test('has multiboot2 and uefi', () {
      expect(X86BootMode.values, containsAll([
        X86BootMode.multiboot2,
        X86BootMode.uefi,
      ]));
    });
  });

  group('X86Bootloader — Multiboot2', () {
    late X86Bootloader bl;

    setUp(() {
      bl = X86Bootloader(bootMode: X86BootMode.multiboot2);
    });

    test('generateBootloaderAsm returns non-empty string', () {
      expect(bl.generateBootloaderAsm(), isNotEmpty);
    });

    test('generated ASM contains Multiboot2 magic', () {
      expect(bl.generateBootloaderAsm(), contains('0xE85250D6'));
    });

    test('generated ASM contains _start32 entry point', () {
      expect(bl.generateBootloaderAsm(), contains('_start32'));
    });

    test('generated ASM contains _start64 code', () {
      expect(bl.generateBootloaderAsm(), contains('_start64'));
    });

    test('generated ASM contains GDT descriptor', () {
      expect(bl.generateBootloaderAsm(), contains('gdt'));
    });

    test('generated ASM contains page table setup', () {
      expect(bl.generateBootloaderAsm(), contains('pml4'));
    });

    test('escaped dollar signs do not produce Dart interpolation errors', () {
      // If $ signs were not escaped, this would throw at generation time.
      expect(() => bl.generateBootloaderAsm(), returnsNormally);
    });

    test('generateLinkerScript returns non-empty string', () {
      expect(bl.generateLinkerScript(), isNotEmpty);
    });

    test('linker script has x86-64 output arch', () {
      expect(bl.generateLinkerScript(), contains('x86-64'));
    });

    test('linker script ENTRY is _start32', () {
      expect(bl.generateLinkerScript(), contains('_start32'));
    });

    test('linker script contains multiboot section', () {
      expect(bl.generateLinkerScript(), contains('.multiboot'));
    });

    test('linker script contains kernelLoadAddress', () {
      final bl2 = X86Bootloader(kernelLoadAddress: 0x200000);
      expect(bl2.generateLinkerScript(), contains('200000'));
    });
  });

  group('X86Bootloader — UEFI', () {
    late X86Bootloader bl;

    setUp(() {
      bl = X86Bootloader(bootMode: X86BootMode.uefi);
    });

    test('generateBootloaderAsm returns non-empty string', () {
      expect(bl.generateBootloaderAsm(), isNotEmpty);
    });

    test('UEFI stub contains _start entry', () {
      expect(bl.generateBootloaderAsm(), contains('_start'));
    });

    test('UEFI stub calls efi_main', () {
      expect(bl.generateBootloaderAsm(), contains('efi_main'));
    });

    test('UEFI linker script uses pei-x86-64 format', () {
      expect(bl.generateLinkerScript(), contains('pei-x86-64'));
    });
  });

  group('X86Bootloader.writeFiles', () {
    late X86Bootloader bl;

    setUp(() {
      bl = X86Bootloader(bootMode: X86BootMode.multiboot2);
    });

    test('creates .S and .ld files in output dir', () async {
      final dir = Directory.systemTemp.createTempSync('x86_bl_test_');
      try {
        await bl.writeFiles(dir.path);
        final files = dir.listSync().map((e) => e.path).toList();
        expect(files.any((f) => f.endsWith('.S')),  isTrue);
        expect(files.any((f) => f.endsWith('.ld')), isTrue);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
