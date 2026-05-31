/// FFI bridge between Dart and bare-metal C / Assembly routines.
///
/// On bare metal, Dart uses `dart:ffi` to call directly into C functions
/// compiled into the same image. This module provides:
///   • MMIO register access helpers (`mmioRead32`, `mmioWrite32`)
///   • Cache management (clean / invalidate D-cache lines)
///   • CPU control helpers (WFI, WFE, DSB, ISB, DMB)
///   • DMA transfer descriptors and helpers
///   • Inline assembly wrappers (modelled as Dart stubs for host simulation)
library;

import 'dart:typed_data';
import 'package:logging/logging.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MMIO register access
// ─────────────────────────────────────────────────────────────────────────────

/// Memory-mapped I/O register access.
///
/// In a real AOT build these would call native C functions via `dart:ffi`.
/// In the host-side simulation they log the access and return safe defaults.
abstract final class MMIO {
  static final _log = Logger('MMIO');

  // ─── 32-bit access ─────────────────────────────────────────────────────────

  /// Read a 32-bit value from the hardware register at [physicalAddress].
  static int read32(int physicalAddress) {
    _log.fine('MMIO.read32(0x${physicalAddress.toRadixString(16)})');
    // Real: return *(volatile uint32_t*)physicalAddress;
    return 0;
  }

  /// Write [value] to the 32-bit hardware register at [physicalAddress].
  static void write32(int physicalAddress, int value) {
    _log.fine('MMIO.write32(0x${physicalAddress.toRadixString(16)}, '
        '0x${value.toRadixString(16)})');
    // Real: *(volatile uint32_t*)physicalAddress = value;
  }

  // ─── 16-bit access ─────────────────────────────────────────────────────────

  static int read16(int physicalAddress) {
    _log.fine('MMIO.read16(0x${physicalAddress.toRadixString(16)})');
    return 0;
  }

  static void write16(int physicalAddress, int value) {
    _log.fine('MMIO.write16(0x${physicalAddress.toRadixString(16)}, '
        '0x${(value & 0xFFFF).toRadixString(16)})');
  }

  // ─── 8-bit access ──────────────────────────────────────────────────────────

  static int read8(int physicalAddress) {
    _log.fine('MMIO.read8(0x${physicalAddress.toRadixString(16)})');
    return 0;
  }

  static void write8(int physicalAddress, int value) {
    _log.fine('MMIO.write8(0x${physicalAddress.toRadixString(16)}, '
        '0x${(value & 0xFF).toRadixString(16)})');
  }

  // ─── 64-bit access ─────────────────────────────────────────────────────────

  static int read64(int physicalAddress) {
    _log.fine('MMIO.read64(0x${physicalAddress.toRadixString(16)})');
    return 0;
  }

  static void write64(int physicalAddress, int value) {
    _log.fine('MMIO.write64(0x${physicalAddress.toRadixString(16)}, '
        '0x${value.toRadixString(16)})');
  }

  // ─── Bit-field helpers ─────────────────────────────────────────────────────

  /// Set specific [bits] in the register at [address].
  static void setBits(int address, int bits) {
    write32(address, read32(address) | bits);
  }

  /// Clear specific [bits] in the register at [address].
  static void clearBits(int address, int bits) {
    write32(address, read32(address) & ~bits);
  }

  /// Update a bit-field: clear [mask], then OR in [value] (already shifted).
  static void updateField(int address, int mask, int value) {
    write32(address, (read32(address) & ~mask) | (value & mask));
  }

  /// Read-modify-write: pass current value through [fn] and write back.
  static void modify32(int address, int Function(int current) fn) {
    write32(address, fn(read32(address)));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CPU control instructions (barriers, WFI/WFE)
// ─────────────────────────────────────────────────────────────────────────────

/// Wrappers for ARM CPU control instructions.
abstract final class CPU {
  /// Data Synchronisation Barrier — ensures all memory accesses complete.
  static void dsb() {
    // Real: __asm__ volatile("dsb sy");
  }

  /// Data Memory Barrier — ensures ordering of memory accesses.
  static void dmb() {
    // Real: __asm__ volatile("dmb sy");
  }

  /// Instruction Synchronisation Barrier — flushes instruction pipeline.
  static void isb() {
    // Real: __asm__ volatile("isb");
  }

  /// Wait For Interrupt — low-power idle until an IRQ fires.
  static void wfi() {
    // Real: __asm__ volatile("wfi");
  }

  /// Wait For Event — low-power idle until an event signal.
  static void wfe() {
    // Real: __asm__ volatile("wfe");
  }

  /// Send Event — wake all CPUs waiting on WFE.
  static void sev() {
    // Real: __asm__ volatile("sev");
  }

  /// No-operation.
  static void nop() {
    // Real: __asm__ volatile("nop");
  }

  /// Read the cycle counter (PMCCNTR_EL0 on AArch64).
  static int readCycleCounter() {
    // Real: uint64_t val; __asm__("mrs %0, pmccntr_el0" : "=r"(val)); return val;
    return DateTime.now().microsecondsSinceEpoch * 1000;
  }

  /// Read the current exception level (AArch64 only).
  static int readCurrentEL() {
    // Real: uint64_t el; __asm__("mrs %0, currentel" : "=r"(el)); return (el >> 2) & 3;
    return 1; // EL1 (kernel)
  }

  /// Read CPSR / DAIF flags.
  static int readDaif() {
    // Real: uint64_t daif; __asm__("mrs %0, daif" : "=r"(daif)); return daif;
    return 0;
  }

  /// Enable IRQs (clear I-bit in DAIF).
  static void enableIrq() {
    // Real: __asm__ volatile("msr daifclr, #2");
  }

  /// Disable IRQs (set I-bit in DAIF).
  static void disableIrq() {
    // Real: __asm__ volatile("msr daifset, #2");
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cache management
// ─────────────────────────────────────────────────────────────────────────────

/// D-cache and I-cache management operations.
abstract final class Cache {
  static final _log = Logger('Cache');

  /// Clean and invalidate a D-cache line containing [address].
  static void cleanInvalidateLine(int address) {
    CPU.dsb();
    _log.fine('D-cache clean+inv at 0x${address.toRadixString(16)}');
    // Real: __asm__ volatile("dc civac, %0" :: "r"(address));
    CPU.dsb();
    CPU.isb();
  }

  /// Clean (write-back) a D-cache line.
  static void cleanLine(int address) {
    CPU.dsb();
    _log.fine('D-cache clean at 0x${address.toRadixString(16)}');
    // Real: __asm__ volatile("dc cvac, %0" :: "r"(address));
    CPU.dsb();
  }

  /// Invalidate a D-cache line (discard without write-back).
  static void invalidateLine(int address) {
    CPU.dsb();
    _log.fine('D-cache inv at 0x${address.toRadixString(16)}');
    // Real: __asm__ volatile("dc ivac, %0" :: "r"(address));
    CPU.dsb();
  }

  /// Invalidate a region of D-cache covering [base] … [base+length].
  static void invalidateRegion(int base, int length) {
    const cacheLineSize = 64;
    var addr = base & ~(cacheLineSize - 1);
    while (addr < base + length) {
      invalidateLine(addr);
      addr += cacheLineSize;
    }
  }

  /// Clean the entire D-cache (write all dirty lines back to RAM).
  static void cleanAll() {
    _log.fine('D-cache clean all');
    // Real: iterate all cache sets/ways and issue DC CSW
  }

  /// Invalidate the entire I-cache.
  static void invalidateICache() {
    CPU.isb();
    _log.fine('I-cache invalidate all');
    // Real: __asm__ volatile("ic ialluis");
    CPU.isb();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DMA transfer descriptors
// ─────────────────────────────────────────────────────────────────────────────

/// DMA transfer direction.
enum DmaDirection { memToMem, memToPeripheral, peripheralToMem }

/// A descriptor for a single DMA transfer.
final class DmaDescriptor {
  final int sourceAddress;
  final int destAddress;
  final int byteCount;
  final DmaDirection direction;
  final bool useInterrupt;
  final int? channel;

  const DmaDescriptor({
    required this.sourceAddress,
    required this.destAddress,
    required this.byteCount,
    this.direction   = DmaDirection.memToMem,
    this.useInterrupt = true,
    this.channel,
  });

  @override
  String toString() =>
      'DmaDescriptor(src=0x${sourceAddress.toRadixString(16)}, '
      'dst=0x${destAddress.toRadixString(16)}, '
      'bytes=$byteCount, dir=${direction.name})';
}

/// Simple DMA controller abstraction.
final class DmaController {
  static final _log = Logger('DmaController');

  final int baseAddress;

  DmaController({required this.baseAddress});

  /// Submit a DMA transfer and wait for completion (polling).
  Future<void> transfer(DmaDescriptor desc) async {
    _log.fine('DMA transfer: $desc');

    // Write source address
    MMIO.write32(baseAddress + 0x00, desc.sourceAddress);
    // Write destination address
    MMIO.write32(baseAddress + 0x04, desc.destAddress);
    // Write byte count
    MMIO.write32(baseAddress + 0x08, desc.byteCount);
    // Set direction and start
    MMIO.write32(baseAddress + 0x0C, desc.direction.index | 0x01);

    // Poll until complete
    var timeout = 10000;
    while ((MMIO.read32(baseAddress + 0x10) & 0x01) != 0 && timeout-- > 0) {
      CPU.nop();
    }

    if (timeout <= 0) {
      _log.severe('DMA timeout!');
    } else {
      _log.fine('DMA complete: ${desc.byteCount} bytes');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PhysicalMemory — raw memory copy / fill helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Low-level physical memory operations (analogous to `memcpy` / `memset`).
abstract final class PhysicalMemory {
  /// Copy [length] bytes from [src] to [dst].
  static void copy(int dst, int src, int length) {
    // In a real FFI build: call native memcpy
    // In simulation: operate on a Uint8List shadow buffer
  }

  /// Fill [length] bytes at [address] with [value].
  static void fill(int address, int value, int length) {
    // Real: memset(address, value, length)
  }

  /// Compare [length] bytes at [a] and [b].
  ///
  /// Returns 0 if equal, <0 if a<b, >0 if a>b.
  static int compare(int a, int b, int length) {
    // Real: return memcmp(a, b, length)
    return 0;
  }

  /// Read a block of [length] bytes from [physicalAddress] into a [Uint8List].
  static Uint8List readBlock(int physicalAddress, int length) {
    // In simulation: return zeroed buffer
    return Uint8List(length);
  }

  /// Write a [Uint8List] to [physicalAddress].
  static void writeBlock(int physicalAddress, Uint8List data) {
    // Real: memcpy(physicalAddress, data.buffer.asUint8List(), data.length)
  }
}
