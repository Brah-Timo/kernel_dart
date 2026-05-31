/// ELF (Executable and Linkable Format) parser.
///
/// Parses 32-bit and 64-bit ELF binaries to extract:
///   • Program headers (load segments)
///   • Section headers (code, data, BSS, etc.)
///   • Symbol table
///   • Entry point address
library;

import 'dart:typed_data';
import 'package:logging/logging.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ELF constants
// ─────────────────────────────────────────────────────────────────────────────

abstract final class ElfConst {
  // e_type
  static const int et_none = 0;
  static const int et_rel  = 1;
  static const int et_exec = 2;
  static const int et_dyn  = 3;
  static const int et_core = 4;

  // e_machine
  static const int em_arm   = 40;
  static const int em_aarch64 = 183;
  static const int em_x86_64 = 62;
  static const int em_riscv  = 243;

  // e_class
  static const int elfClass32 = 1;
  static const int elfClass64 = 2;

  // e_data (endianness)
  static const int elfDataLsb = 1; // Little-endian
  static const int elfDataMsb = 2; // Big-endian

  // p_type
  static const int pt_null    = 0;
  static const int pt_load    = 1;
  static const int pt_dynamic = 2;
  static const int pt_interp  = 3;
  static const int pt_note    = 4;
  static const int pt_phdr    = 6;

  // p_flags
  static const int pf_x = 1; // Executable
  static const int pf_w = 2; // Writable
  static const int pf_r = 4; // Readable

  // sh_type
  static const int sht_null     = 0;
  static const int sht_progbits = 1;
  static const int sht_symtab   = 2;
  static const int sht_strtab   = 3;
  static const int sht_rela     = 4;
  static const int sht_nobits   = 8;  // BSS
}

// ─────────────────────────────────────────────────────────────────────────────
// Data classes
// ─────────────────────────────────────────────────────────────────────────────

/// ELF file header metadata.
final class ElfHeader {
  final int elfClass;    // 32 or 64
  final int endian;      // 1=LE, 2=BE
  final int fileType;    // ET_*
  final int machine;     // EM_*
  final int version;
  final int entryPoint;
  final int phOffset;    // program header table offset
  final int shOffset;    // section header table offset
  final int phCount;     // program header count
  final int shCount;     // section header count
  final int shStrIndex;  // section name string table index

  const ElfHeader({
    required this.elfClass,
    required this.endian,
    required this.fileType,
    required this.machine,
    required this.version,
    required this.entryPoint,
    required this.phOffset,
    required this.shOffset,
    required this.phCount,
    required this.shCount,
    required this.shStrIndex,
  });

  bool get is64bit    => elfClass == ElfConst.elfClass64;
  bool get isLittleEndian => endian == ElfConst.elfDataLsb;
  String get machineStr => switch (machine) {
        ElfConst.em_arm     => 'ARM',
        ElfConst.em_aarch64 => 'AArch64',
        ElfConst.em_x86_64  => 'x86-64',
        ElfConst.em_riscv   => 'RISC-V',
        _ => 'Machine($machine)',
      };

  @override
  String toString() =>
      'ElfHeader(${is64bit ? "64-bit" : "32-bit"} ${isLittleEndian ? "LE" : "BE"} '
      '$machineStr, entry=0x${entryPoint.toRadixString(16)})';
}

/// An ELF program header (load segment).
final class ElfProgramHeader {
  final int type;
  final int flags;
  final int fileOffset;
  final int virtualAddr;
  final int physicalAddr;
  final int fileSize;
  final int memorySize;
  final int alignment;

  const ElfProgramHeader({
    required this.type,
    required this.flags,
    required this.fileOffset,
    required this.virtualAddr,
    required this.physicalAddr,
    required this.fileSize,
    required this.memorySize,
    required this.alignment,
  });

  bool get isLoad       => type == ElfConst.pt_load;
  bool get isExecutable => (flags & ElfConst.pf_x) != 0;
  bool get isWritable   => (flags & ElfConst.pf_w) != 0;
  bool get isReadable   => (flags & ElfConst.pf_r) != 0;

  String get typeStr => switch (type) {
        ElfConst.pt_null    => 'NULL',
        ElfConst.pt_load    => 'LOAD',
        ElfConst.pt_dynamic => 'DYNAMIC',
        ElfConst.pt_interp  => 'INTERP',
        ElfConst.pt_note    => 'NOTE',
        _ => 'PT_$type',
      };

  @override
  String toString() =>
      'PH($typeStr flags=${isReadable ? 'R' : '-'}${isWritable ? 'W' : '-'}${isExecutable ? 'X' : '-'} '
      'vaddr=0x${virtualAddr.toRadixString(16)} '
      'fsize=$fileSize memsize=$memorySize)';
}

/// An ELF section header.
final class ElfSectionHeader {
  final String name;
  final int type;
  final int flags;
  final int virtualAddr;
  final int fileOffset;
  final int size;
  final int entrySize;

  const ElfSectionHeader({
    required this.name,
    required this.type,
    required this.flags,
    required this.virtualAddr,
    required this.fileOffset,
    required this.size,
    required this.entrySize,
  });

  bool get isBss      => type == ElfConst.sht_nobits;
  bool get isProgbits => type == ElfConst.sht_progbits;

  @override
  String toString() =>
      'SH("$name" vaddr=0x${virtualAddr.toRadixString(16)} size=$size)';
}

/// Parsed ELF binary.
final class ElfBinary {
  final ElfHeader header;
  final List<ElfProgramHeader> programHeaders;
  final List<ElfSectionHeader> sectionHeaders;
  final Uint8List rawBytes;

  const ElfBinary({
    required this.header,
    required this.programHeaders,
    required this.sectionHeaders,
    required this.rawBytes,
  });

  /// LOAD segments only.
  List<ElfProgramHeader> get loadSegments =>
      programHeaders.where((ph) => ph.isLoad).toList();

  /// Compute the total memory footprint (highest memaddr − lowest vaddr).
  int get memoryFootprint {
    if (loadSegments.isEmpty) return 0;
    final minVa = loadSegments.map((s) => s.virtualAddr).reduce((a, b) => a < b ? a : b);
    final maxVa = loadSegments
        .map((s) => s.virtualAddr + s.memorySize)
        .reduce((a, b) => a > b ? a : b);
    return maxVa - minVa;
  }

  /// Extract the raw bytes of a LOAD segment.
  Uint8List segmentBytes(ElfProgramHeader ph) =>
      rawBytes.sublist(ph.fileOffset, ph.fileOffset + ph.fileSize);
}

// ─────────────────────────────────────────────────────────────────────────────
// ElfParser
// ─────────────────────────────────────────────────────────────────────────────

/// Parses an ELF binary from a [Uint8List].
final class ElfParser {
  static final _log = Logger('ElfParser');

  /// Parse [bytes] as an ELF binary.
  ///
  /// Returns null if [bytes] is not a valid ELF file.
  ElfBinary? parse(Uint8List bytes) {
    if (bytes.length < 64) return null;

    // Check ELF magic
    if (bytes[0] != 0x7F || bytes[1] != 0x45 ||
        bytes[2] != 0x4C || bytes[3] != 0x46) {
      _log.warning('Not an ELF file');
      return null;
    }

    final elfClass = bytes[4];
    final endian   = bytes[5];
    final is64     = elfClass == ElfConst.elfClass64;
    final isLE     = endian   == ElfConst.elfDataLsb;
    final bd       = ByteData.sublistView(bytes);

    int u16(int off) => isLE ? bd.getUint16(off, Endian.little) : bd.getUint16(off, Endian.big);
    int u32(int off) => isLE ? bd.getUint32(off, Endian.little) : bd.getUint32(off, Endian.big);
    int u64(int off) => isLE ? bd.getUint64(off, Endian.little) : bd.getUint64(off, Endian.big);
    int addr(int off) => is64 ? u64(off) : u32(off);
    int word(int off) => is64 ? u64(off) : u32(off);

    final fileType   = u16(16);
    final machine    = u16(18);
    final version    = u32(20);
    final entryPoint = addr(is64 ? 24 : 24);
    final phOffset   = word(is64 ? 32 : 28);
    final shOffset   = word(is64 ? 40 : 32);
    final phSize     = u16(is64 ? 54 : 42);
    final phCount    = u16(is64 ? 56 : 44);
    final shSize     = u16(is64 ? 58 : 46);
    final shCount    = u16(is64 ? 60 : 48);
    final shStrIdx   = u16(is64 ? 62 : 50);

    final header = ElfHeader(
      elfClass:    elfClass,
      endian:      endian,
      fileType:    fileType,
      machine:     machine,
      version:     version,
      entryPoint:  entryPoint,
      phOffset:    phOffset,
      shOffset:    shOffset,
      phCount:     phCount,
      shCount:     shCount,
      shStrIndex:  shStrIdx,
    );

    // Parse program headers
    final programHeaders = <ElfProgramHeader>[];
    for (var i = 0; i < phCount; i++) {
      final base = phOffset + i * phSize;
      programHeaders.add(ElfProgramHeader(
        type:         u32(base),
        flags:        is64 ? u32(base + 4) : u32(base + 24),
        fileOffset:   word(is64 ? base + 8  : base + 4),
        virtualAddr:  addr(is64 ? base + 16 : base + 8),
        physicalAddr: addr(is64 ? base + 24 : base + 12),
        fileSize:     word(is64 ? base + 32 : base + 16),
        memorySize:   word(is64 ? base + 40 : base + 20),
        alignment:    word(is64 ? base + 48 : base + 28),
      ));
    }

    // Parse section headers
    final sectionHeaders = <ElfSectionHeader>[];
    for (var i = 0; i < shCount; i++) {
      final base = shOffset + i * shSize;
      sectionHeaders.add(ElfSectionHeader(
        name:        '', // name resolution needs shstrtab
        type:        u32(base + 4),
        flags:       word(is64 ? base + 8  : base + 8),
        virtualAddr: addr(is64 ? base + 16 : base + 12),
        fileOffset:  word(is64 ? base + 24 : base + 16),
        size:        word(is64 ? base + 32 : base + 20),
        entrySize:   word(is64 ? base + 56 : base + 36),
      ));
    }

    _log.fine('Parsed: $header (${programHeaders.length} PH, ${sectionHeaders.length} SH)');
    return ElfBinary(
      header:         header,
      programHeaders: programHeaders,
      sectionHeaders: sectionHeaders,
      rawBytes:       bytes,
    );
  }
}
