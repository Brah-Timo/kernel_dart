import 'dart:typed_data';

import 'package:kernel_dart/src/utils/elf_parser.dart';
import 'package:test/test.dart';

// Build a minimal valid ELF64 header (64 bytes) for testing.
Uint8List _buildMinimalElf64({
  bool littleEndian = true,
  int machine       = 0x00B7, // AArch64
  int eType         = 2,      // ET_EXEC
}) {
  final buf = Uint8List(64);
  final bd  = ByteData.sublistView(buf);

  // e_ident
  buf[0] = 0x7F; buf[1] = 0x45; buf[2] = 0x4C; buf[3] = 0x46; // Magic
  buf[4] = 2;    // EI_CLASS  = ELFCLASS64
  buf[5] = littleEndian ? 1 : 2; // EI_DATA
  buf[6] = 1;    // EI_VERSION
  buf[7] = 0;    // EI_OSABI

  final end = littleEndian ? Endian.little : Endian.big;

  // e_type, e_machine, e_version
  bd.setUint16(16, eType,   end);
  bd.setUint16(18, machine, end);
  bd.setUint32(20, 1,       end); // e_version = 1

  // e_entry = 0x80000
  bd.setUint64(24, 0x80000, end);

  // e_phoff = 0 (no program headers)
  bd.setUint64(32, 0, end);
  // e_shoff = 0 (no section headers)
  bd.setUint64(40, 0, end);

  // e_flags = 0
  bd.setUint32(48, 0, end);

  // e_ehsize = 64
  bd.setUint16(52, 64, end);
  // e_phentsize = 56, e_phnum = 0
  bd.setUint16(54, 56, end);
  bd.setUint16(56, 0,  end);
  // e_shentsize = 64, e_shnum = 0
  bd.setUint16(58, 64, end);
  bd.setUint16(60, 0,  end);
  // e_shstrndx = 0
  bd.setUint16(62, 0, end);

  return buf;
}

void main() {
  group('ElfParser.parse — valid ELF64', () {
    test('parses without throwing and returns non-null', () {
      final parser = ElfParser();
      final result = parser.parse(_buildMinimalElf64());
      expect(result, isNotNull);
    });

    test('detects 64-bit ELF', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64())!;
      expect(elf.header.is64bit, isTrue);
    });

    test('detects little-endian', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64(littleEndian: true))!;
      expect(elf.header.isLittleEndian, isTrue);
    });

    test('detects big-endian', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64(littleEndian: false))!;
      expect(elf.header.isLittleEndian, isFalse);
    });

    test('parses entry point address', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64())!;
      expect(elf.header.entryPoint, equals(0x80000));
    });

    test('parses machine type (AArch64 = 0xB7 = 183)', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64(machine: 0x00B7))!;
      expect(elf.header.machine, equals(ElfConst.em_aarch64));
    });

    test('parses x86-64 machine type (0x3E = 62)', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64(machine: 0x003E))!;
      expect(elf.header.machine, equals(ElfConst.em_x86_64));
    });

    test('parses ELF type (ET_EXEC = 2)', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64(eType: 2))!;
      expect(elf.header.fileType, equals(ElfConst.et_exec));
    });

    test('program headers list is empty for phnum=0', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64())!;
      expect(elf.programHeaders, isEmpty);
    });

    test('section headers list is empty for shnum=0', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64())!;
      expect(elf.sectionHeaders, isEmpty);
    });

    test('loadSegments is empty when no LOAD program headers', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64())!;
      expect(elf.loadSegments, isEmpty);
    });

    test('rawBytes contains the original bytes', () {
      final bytes  = _buildMinimalElf64();
      final parser = ElfParser();
      final elf    = parser.parse(bytes)!;
      expect(elf.rawBytes.length, equals(64));
    });
  });

  group('ElfParser.parse — invalid data', () {
    test('returns null for empty bytes (too short)', () {
      final parser = ElfParser();
      expect(parser.parse(Uint8List(0)), isNull);
    });

    test('returns null for wrong magic', () {
      final parser = ElfParser();
      final bad = Uint8List.fromList([0x00, 0x00, 0x00, 0x00, ...List.filled(60, 0)]);
      expect(parser.parse(bad), isNull);
    });

    test('returns null for too-short header (< 64 bytes)', () {
      final parser = ElfParser();
      final truncated = Uint8List(16)
        ..[0] = 0x7F ..[1] = 0x45 ..[2] = 0x4C ..[3] = 0x46;
      expect(parser.parse(truncated), isNull);
    });
  });

  group('ElfHeader', () {
    test('machineStr returns AArch64 for machine 183', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64(machine: ElfConst.em_aarch64))!;
      expect(elf.header.machineStr, equals('AArch64'));
    });

    test('machineStr returns x86-64 for machine 62', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64(machine: ElfConst.em_x86_64))!;
      expect(elf.header.machineStr, equals('x86-64'));
    });

    test('toString contains bit-width and machine', () {
      final parser = ElfParser();
      final elf = parser.parse(_buildMinimalElf64())!;
      final str = elf.header.toString();
      expect(str, contains('64-bit'));
    });
  });

  group('ElfConst values', () {
    test('ET_EXEC is 2', () => expect(ElfConst.et_exec, equals(2)));
    test('EM_AARCH64 is 183', () => expect(ElfConst.em_aarch64, equals(183)));
    test('EM_X86_64 is 62',  () => expect(ElfConst.em_x86_64,  equals(62)));
    test('EM_ARM is 40',     () => expect(ElfConst.em_arm,     equals(40)));
  });
}
