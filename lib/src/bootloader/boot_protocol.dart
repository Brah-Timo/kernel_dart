/// Boot protocol definitions shared across all bootloader implementations.
///
/// Defines the in-memory structures that the bootloader passes to the kernel,
/// modelled after UEFI System Tables and the Linux x86 Boot Protocol.
library;

// ─────────────────────────────────────────────────────────────────────────────
// Memory descriptor
// ─────────────────────────────────────────────────────────────────────────────

/// Type of a physical memory region.
enum MemoryType {
  /// Usable RAM.
  conventional,

  /// Reserved by firmware; must not be used.
  reserved,

  /// ACPI reclaimable memory.
  acpiReclaimable,

  /// ACPI non-volatile storage.
  acpiNvs,

  /// Memory-mapped I/O.
  mmio,

  /// Memory-mapped I/O port space.
  mmioPortSpace,

  /// PAL (Platform Abstraction Layer) code.
  palCode,

  /// Persistent memory (NVDIMM).
  persistent,

  /// Boot-services code (can be reclaimed post-boot).
  bootServicesCode,

  /// Bootloader data (can be reclaimed after handoff).
  bootloaderData,

  /// Kernel code / data.
  kernelCode,
}

/// Describes a contiguous physical memory region.
final class MemoryDescriptor {
  final MemoryType type;

  /// Physical base address of the region.
  final int physicalStart;

  /// Size of the region in bytes.
  final int sizeBytes;

  /// Whether the region is mapped in the virtual address space.
  final bool virtuallyMapped;

  const MemoryDescriptor({
    required this.type,
    required this.physicalStart,
    required this.sizeBytes,
    this.virtuallyMapped = false,
  });

  int get physicalEnd => physicalStart + sizeBytes;

  @override
  String toString() =>
      'MemoryDescriptor(type=${type.name}, '
      'base=0x${physicalStart.toRadixString(16).padLeft(8, '0')}, '
      'size=${sizeBytes} bytes)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Boot command-line and modules
// ─────────────────────────────────────────────────────────────────────────────

/// A kernel module (initrd, device-tree blob, etc.) loaded by the bootloader.
final class BootModule {
  /// Physical start address of the module in RAM.
  final int physicalStart;

  /// Size in bytes.
  final int sizeBytes;

  /// Human-readable label (e.g. 'initrd', 'dtb').
  final String label;

  const BootModule({
    required this.physicalStart,
    required this.sizeBytes,
    required this.label,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// BootInfo — the central hand-off structure
// ─────────────────────────────────────────────────────────────────────────────

/// Information passed from the bootloader to the kernel at handoff.
///
/// The bootloader constructs and populates this structure, then passes a
/// pointer to it in a CPU register (r0/x0 on ARM, rdi on x86-64) before
/// jumping to the kernel entry point.
final class BootInfo {
  /// Magic signature: `0xB007DA37` ('BOOTDART').
  static const int magic = 0xB007DA37;

  /// Version of the BootInfo structure (for forward compatibility).
  final int version;

  /// Physical memory map provided by firmware.
  final List<MemoryDescriptor> memoryMap;

  /// Kernel command-line arguments (null-terminated C string contents).
  final String commandLine;

  /// Optional additional modules (initrd, device-tree, etc.).
  final List<BootModule> modules;

  /// Framebuffer info (optional — null if no display).
  final FramebufferInfo? framebuffer;

  /// UART base address detected/configured by bootloader.
  final int uartBase;

  /// CPU clock frequency in Hz.
  final int cpuClockHz;

  /// Total detected RAM in bytes.
  final int totalRamBytes;

  const BootInfo({
    this.version        = 1,
    required this.memoryMap,
    this.commandLine    = '',
    this.modules        = const [],
    this.framebuffer,
    required this.uartBase,
    required this.cpuClockHz,
    required this.totalRamBytes,
  });

  /// Total usable (conventional) RAM derived from memory map.
  int get usableRamBytes => memoryMap
      .where((d) => d.type == MemoryType.conventional)
      .fold(0, (sum, d) => sum + d.sizeBytes);

  /// Locate the largest contiguous usable RAM region (ideal for the heap).
  MemoryDescriptor? get largestFreeRegion {
    MemoryDescriptor? best;
    for (final d in memoryMap) {
      if (d.type != MemoryType.conventional) continue;
      if (best == null || d.sizeBytes > best.sizeBytes) best = d;
    }
    return best;
  }

  @override
  String toString() =>
      'BootInfo(v$version, RAM=${totalRamBytes >> 20} MB, '
      'uart=0x${uartBase.toRadixString(16)}, '
      'clock=${cpuClockHz ~/ 1000000} MHz)';
}

/// Framebuffer geometry and pixel format.
final class FramebufferInfo {
  final int physicalBase;
  final int width;
  final int height;
  final int pitch;  // bytes per row
  final PixelFormat format;

  const FramebufferInfo({
    required this.physicalBase,
    required this.width,
    required this.height,
    required this.pitch,
    required this.format,
  });
}

/// Pixel colour format.
enum PixelFormat { rgb888, bgr888, rgba8888, argb8888 }

// ─────────────────────────────────────────────────────────────────────────────
// BootProtocol — serialisation helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Serialises / deserialises [BootInfo] to a flat byte buffer
/// that can be placed in RAM before jumping to the kernel.
abstract final class BootProtocol {
  static const int _headerSize = 64;

  /// Serialise [info] to bytes (little-endian).
  static List<int> encode(BootInfo info) {
    final buf = <int>[];

    // Header: magic (4 bytes) + version (4 bytes) + map count (4 bytes) + padding
    buf.addAll(_u32le(BootInfo.magic));
    buf.addAll(_u32le(info.version));
    buf.addAll(_u32le(info.memoryMap.length));
    buf.addAll(_u32le(info.uartBase));
    buf.addAll(_u32le(info.cpuClockHz));
    buf.addAll(_u64le(info.totalRamBytes));
    // Fill header to _headerSize bytes
    while (buf.length < _headerSize) buf.add(0);

    // Memory map entries (each 24 bytes: type4 + physBase8 + size8 + flags4)
    for (final d in info.memoryMap) {
      buf.addAll(_u32le(d.type.index));
      buf.addAll(_u64le(d.physicalStart));
      buf.addAll(_u64le(d.sizeBytes));
      buf.addAll(_u32le(d.virtuallyMapped ? 1 : 0));
    }

    // Command line (null-terminated UTF-8)
    buf.addAll(info.commandLine.codeUnits);
    buf.add(0); // null terminator

    // Pad to 4-byte boundary
    while (buf.length % 4 != 0) buf.add(0);

    return buf;
  }

  static List<int> _u32le(int v) => [
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
      ];

  static List<int> _u64le(int v) => [
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF,
        (v >> 32) & 0xFF,
        (v >> 40) & 0xFF,
        (v >> 48) & 0xFF,
        (v >> 56) & 0xFF,
      ];
}
