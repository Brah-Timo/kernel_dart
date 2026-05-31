/// Physical memory layout definitions for each supported platform.
library;

import 'platform_config.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MemoryRegion
// ─────────────────────────────────────────────────────────────────────────────

/// A contiguous physical memory region with a human-readable name.
final class MemoryRegion {
  final String name;
  final int start;
  final int sizeBytes;
  final bool readable;
  final bool writable;
  final bool executable;
  final bool cacheEnabled;

  const MemoryRegion({
    required this.name,
    required this.start,
    required this.sizeBytes,
    this.readable     = true,
    this.writable     = true,
    this.executable   = false,
    this.cacheEnabled = true,
  });

  int get end => start + sizeBytes;

  bool contains(int address) => address >= start && address < end;

  @override
  String toString() =>
      '$name: 0x${start.toRadixString(16).padLeft(8, '0')}–'
      '0x${end.toRadixString(16).padLeft(8, '0')} '
      '(${sizeBytes >> 10} KB)';
}

// ─────────────────────────────────────────────────────────────────────────────
// MemoryLayout
// ─────────────────────────────────────────────────────────────────────────────

/// Complete physical memory layout for a target platform.
final class MemoryLayout {
  final PlatformConfig platform;
  final List<MemoryRegion> regions;

  const MemoryLayout({required this.platform, required this.regions});

  /// Find the region containing [address].
  MemoryRegion? regionAt(int address) {
    for (final r in regions) {
      if (r.contains(address)) return r;
    }
    return null;
  }

  // ─── Factory: build layout from platform config ───────────────────────────

  factory MemoryLayout.forPlatform(PlatformConfig cfg) {
    final ramBase = cfg.ramBase;

    return MemoryLayout(
      platform: cfg,
      regions: [
        MemoryRegion(
          name:       'Bootloader',
          start:      ramBase,
          sizeBytes:  0x8000,        // 32 KB
          executable: true,
          writable:   false,
        ),
        MemoryRegion(
          name:       'Kernel Code & Data',
          start:      ramBase + 0x8000,
          sizeBytes:  0x80000,       // 512 KB
          executable: true,
        ),
        MemoryRegion(
          name:       'Dart Runtime',
          start:      ramBase + 0x88000,
          sizeBytes:  0x80000,       // 512 KB
          executable: true,
        ),
        MemoryRegion(
          name:       'Device Drivers',
          start:      ramBase + 0x108000,
          sizeBytes:  0x60000,       // 384 KB
          executable: true,
        ),
        MemoryRegion(
          name:       'App Code (AOT Dart)',
          start:      ramBase + 0x168000,
          sizeBytes:  0x80000,       // 512 KB
          executable: true,
        ),
        MemoryRegion(
          name:       'Read-Only Data',
          start:      ramBase + 0x1E8000,
          sizeBytes:  0x20000,       // 128 KB
          writable:   false,
          executable: false,
        ),
        MemoryRegion(
          name:       'Initialised Data',
          start:      ramBase + 0x208000,
          sizeBytes:  0x20000,       // 128 KB
        ),
        MemoryRegion(
          name:       'BSS (zero-init)',
          start:      ramBase + 0x228000,
          sizeBytes:  0x20000,       // 128 KB
        ),
        MemoryRegion(
          name:       'Heap',
          start:      ramBase + 0x248000,
          sizeBytes:  cfg.ramSize - 0x248000 - 0x10000, // up to near end of RAM
        ),
        MemoryRegion(
          name:       'IRQ Stack',
          start:      ramBase + cfg.ramSize - 0x10000,
          sizeBytes:  0x10000,       // 64 KB at top of RAM
        ),
        MemoryRegion(
          name:       'Memory-Mapped I/O',
          start:      cfg.uartBase & ~0xFFFFF, // align to 1 MB boundary
          sizeBytes:  0x01000000,    // 16 MB MMIO window
          cacheEnabled: false,
        ),
      ],
    );
  }

  // ─── Linker symbol values ─────────────────────────────────────────────────

  /// Map of symbol name → address for use in linker scripts.
  Map<String, int> get linkerSymbols {
    final base = platform.ramBase;
    return {
      '__boot_start':   base,
      '__kernel_start': base + 0x8000,
      '__runtime_start':base + 0x88000,
      '__drivers_start':base + 0x108000,
      '__app_start':    base + 0x168000,
      '__rodata_start': base + 0x1E8000,
      '__data_start':   base + 0x208000,
      '__bss_start':    base + 0x228000,
      '__bss_end':      base + 0x248000,
      '__heap_start':   base + 0x248000,
      '__heap_end':     base + platform.ramSize - 0x10000,
      '__stack_top':    base + platform.ramSize,
    };
  }

  @override
  String toString() {
    final buf = StringBuffer('MemoryLayout(${platform.name})\n');
    for (final r in regions) buf.writeln('  $r');
    return buf.toString();
  }
}
