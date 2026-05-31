/// Bare-metal memory manager for the kernel_dart microkernel.
///
/// Implements:
///   • A **First-Fit / Best-Fit** block allocator for the kernel heap
///   • A simple **mark-and-sweep garbage collector** (triggered manually or
///     when free memory drops below a configurable threshold)
///   • Memory statistics and fragmentation reporting
///   • Virtual-to-physical address translation stubs (for MMU support)
library;

import 'dart:math' as math;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Pointer — typed bare-metal address
// ─────────────────────────────────────────────────────────────────────────────

/// An untyped bare-metal memory address (a 64-bit integer handle).
///
/// On a real system this would be an `int*` / `void*`; here it is modelled
/// as a plain [int] so the Dart host-side tooling can work with it.
typedef Pointer = int;

const Pointer nullPtr = 0;

// ─────────────────────────────────────────────────────────────────────────────
// MemoryBlock
// ─────────────────────────────────────────────────────────────────────────────

/// A contiguous region of the kernel heap.
final class MemoryBlock {
  /// Physical start address.
  final Pointer address;

  /// Requested size in bytes (aligned to [MemoryManager.alignment]).
  int sizeBytes;

  /// Whether this block is currently in use.
  bool isAllocated;

  /// Number of live references tracked by the GC.
  int refCount;

  /// GC mark bit (used during the mark phase).
  bool marked;

  MemoryBlock({
    required this.address,
    required this.sizeBytes,
    this.isAllocated = false,
    this.refCount    = 0,
    this.marked      = false,
  });

  Pointer get endAddress => address + sizeBytes;

  @override
  String toString() =>
      'MemoryBlock(addr=0x${address.toRadixString(16).padLeft(8, '0')}, '
      'size=$sizeBytes, allocated=$isAllocated)';
}

// ─────────────────────────────────────────────────────────────────────────────
// MemoryStats
// ─────────────────────────────────────────────────────────────────────────────

/// Snapshot of the memory subsystem state.
final class MemoryStats {
  final int totalMemory;
  final int usedMemory;
  final int freeMemory;
  final int blockCount;
  final int allocatedBlocks;
  final int freeBlocks;
  final double fragmentationRatio;
  final int gcRunCount;
  final int gcBytesCollected;

  const MemoryStats({
    required this.totalMemory,
    required this.usedMemory,
    required this.freeMemory,
    required this.blockCount,
    required this.allocatedBlocks,
    required this.freeBlocks,
    required this.fragmentationRatio,
    required this.gcRunCount,
    required this.gcBytesCollected,
  });

  @override
  String toString() =>
      'MemoryStats(\n'
      '  total    : ${totalMemory >> 10} KB\n'
      '  used     : ${usedMemory >> 10} KB\n'
      '  free     : ${freeMemory >> 10} KB\n'
      '  blocks   : $blockCount  ($allocatedBlocks alloc / $freeBlocks free)\n'
      '  fragm.   : ${(fragmentationRatio * 100).toStringAsFixed(1)} %\n'
      '  gc runs  : $gcRunCount  (collected ${gcBytesCollected >> 10} KB total)\n'
      ')';
}

// ─────────────────────────────────────────────────────────────────────────────
// AllocationStrategy
// ─────────────────────────────────────────────────────────────────────────────

/// Allocation strategy used when searching for a free block.
enum AllocationStrategy {
  /// First block that is large enough — fastest allocation, most fragmentation.
  firstFit,

  /// Smallest block that is large enough — least fragmentation, slower search.
  bestFit,

  /// Largest available block — minimises wasted space for large allocations.
  worstFit,
}

// ─────────────────────────────────────────────────────────────────────────────
// MemoryManager
// ─────────────────────────────────────────────────────────────────────────────

/// Kernel heap manager.
///
/// Manages a flat region of physical RAM as a linked list of [MemoryBlock]s.
///
/// ```dart
/// final mm = MemoryManager.init(
///   heapStart : 0x00248000,
///   heapSize  : 0x04000000,  // 64 MB heap
/// );
///
/// final ptr = mm.allocate(1024);
/// // … use memory …
/// mm.deallocate(ptr);
/// ```
final class MemoryManager {
  // ─── Singleton ─────────────────────────────────────────────────────────────

  static MemoryManager? _instance;

  /// Global singleton — initialised once during kernel boot.
  static MemoryManager get instance {
    assert(
      _instance != null,
      'MemoryManager not initialised. Call MemoryManager.init() first.',
    );
    return _instance!;
  }

  // ─── Configuration ──────────────────────────────────────────────────────

  /// Physical start address of the heap region.
  final Pointer heapStart;

  /// Total heap size in bytes.
  final int heapSize;

  /// Minimum allocation alignment (8 bytes for 64-bit platforms).
  static const int alignment = 8;

  /// Free-memory fraction below which automatic GC is triggered.
  final double gcThreshold;

  /// Allocation strategy.
  final AllocationStrategy strategy;

  // ─── Internal state ────────────────────────────────────────────────────

  final List<MemoryBlock> _blocks = [];

  int _gcRunCount = 0;
  int _gcBytesCollected = 0;

  static final _log = Logger('MemoryManager');

  // ─── Constructor & factory ─────────────────────────────────────────────

  MemoryManager._({
    required this.heapStart,
    required this.heapSize,
    this.gcThreshold = 0.1,
    this.strategy    = AllocationStrategy.bestFit,
  }) {
    // Seed with a single large free block covering the entire heap
    _blocks.add(MemoryBlock(address: heapStart, sizeBytes: heapSize));
    _log.info(
      'MemoryManager initialised: '
      'heap=0x${heapStart.toRadixString(16)} size=${heapSize >> 10} KB',
    );
  }

  /// Initialise the global memory manager singleton.
  ///
  /// Must be called exactly once during kernel boot before any allocation.
  factory MemoryManager.init({
    required Pointer heapStart,
    required int heapSize,
    double gcThreshold = 0.1,
    AllocationStrategy strategy = AllocationStrategy.bestFit,
  }) {
    _instance = MemoryManager._(
      heapStart:   heapStart,
      heapSize:    heapSize,
      gcThreshold: gcThreshold,
      strategy:    strategy,
    );
    return _instance!;
  }

  // ─── Allocation ────────────────────────────────────────────────────────

  /// Allocate [sizeBytes] of heap memory.
  ///
  /// Returns a [Pointer] to the allocated region, or [nullPtr] if OOM.
  /// Automatically triggers GC when free memory drops below [gcThreshold].
  Pointer allocate(int sizeBytes) {
    if (sizeBytes <= 0) return nullPtr;

    // Align size to 8-byte boundary
    final aligned = _alignUp(sizeBytes);

    // Auto-GC when memory is low
    final stats = getMemoryStats();
    if (stats.freeMemory / stats.totalMemory < gcThreshold) {
      _log.warning('Memory low (${(stats.freeMemory / 1024).toStringAsFixed(0)} KB free) — running GC');
      runGarbageCollection();
    }

    final block = switch (strategy) {
      AllocationStrategy.firstFit => _firstFit(aligned),
      AllocationStrategy.bestFit  => _bestFit(aligned),
      AllocationStrategy.worstFit => _worstFit(aligned),
    };

    if (block == null) {
      _log.severe('OOM: failed to allocate $aligned bytes');
      return nullPtr;
    }

    _splitBlock(block, aligned);
    block.isAllocated = true;
    block.refCount    = 1;

    _log.fine('allocate($aligned) → 0x${block.address.toRadixString(16)}');
    return block.address;
  }

  /// Allocate [count] × [elementSize] bytes (like `calloc`), zeroed.
  Pointer allocateZeroed(int count, int elementSize) {
    final ptr = allocate(count * elementSize);
    // In a real implementation: memset(ptr, 0, count * elementSize)
    return ptr;
  }

  // ─── Deallocation ──────────────────────────────────────────────────────

  /// Free the memory at [ptr].
  ///
  /// Does nothing if [ptr] is [nullPtr] or not found.
  void deallocate(Pointer ptr) {
    if (ptr == nullPtr) return;

    final block = _blockAt(ptr);
    if (block == null) {
      _log.warning('deallocate: unknown pointer 0x${ptr.toRadixString(16)}');
      return;
    }

    block.isAllocated = false;
    block.refCount    = 0;
    _log.fine('deallocate(0x${ptr.toRadixString(16)}) ${block.sizeBytes} bytes');

    _coalesce();
  }

  // ─── Reference counting ────────────────────────────────────────────────

  /// Increment the reference count of [ptr].
  void retain(Pointer ptr) {
    _blockAt(ptr)?.refCount++;
  }

  /// Decrement the reference count of [ptr] and free if it reaches zero.
  void release(Pointer ptr) {
    final block = _blockAt(ptr);
    if (block == null) return;
    block.refCount = math.max(0, block.refCount - 1);
    if (block.refCount == 0) deallocate(ptr);
  }

  // ─── Garbage collection ────────────────────────────────────────────────

  /// Run a mark-and-sweep garbage collection cycle.
  ///
  /// **Mark phase**: traverses the root set (all blocks with `refCount > 0`)
  ///   and marks them as live.
  /// **Sweep phase**: frees all unmarked, allocated blocks.
  ///
  /// Returns the number of bytes reclaimed.
  int runGarbageCollection() {
    _log.info('GC: starting mark-and-sweep…');
    var reclaimed = 0;

    // ── Mark phase: clear all marks, then re-mark reachable blocks ─────────
    for (final block in _blocks) {
      block.marked = false;
    }

    // Root set: any block with refCount > 0 is reachable
    final roots = _blocks.where((b) => b.isAllocated && b.refCount > 0).toList();
    for (final root in roots) {
      _markReachable(root);
    }

    // ── Sweep phase: free unmarked allocated blocks ─────────────────────────
    for (final block in _blocks) {
      if (block.isAllocated && !block.marked) {
        _log.fine('GC: sweeping 0x${block.address.toRadixString(16)} (${block.sizeBytes}B)');
        reclaimed    += block.sizeBytes;
        block.isAllocated = false;
        block.refCount    = 0;
      }
    }

    _coalesce();

    _gcRunCount++;
    _gcBytesCollected += reclaimed;
    _log.info('GC: reclaimed ${reclaimed >> 10} KB in cycle $_gcRunCount');

    return reclaimed;
  }

  void _markReachable(MemoryBlock block) {
    if (block.marked) return;
    block.marked = true;
    // In a full implementation we would recursively follow pointers
    // stored within this block. Here we mark only the direct block.
  }

  // ─── Statistics ────────────────────────────────────────────────────────

  /// Return a snapshot of the current memory state.
  MemoryStats getMemoryStats() {
    var used       = 0;
    var allocCount = 0;
    var freeCount  = 0;
    var maxFree    = 0;
    var totalFree  = 0;

    for (final b in _blocks) {
      if (b.isAllocated) {
        used       += b.sizeBytes;
        allocCount++;
      } else {
        freeCount++;
        totalFree += b.sizeBytes;
        if (b.sizeBytes > maxFree) maxFree = b.sizeBytes;
      }
    }

    // Fragmentation: 1 – (largest_free / total_free)
    final frag = (totalFree == 0)
        ? 0.0
        : 1.0 - (maxFree / totalFree);

    return MemoryStats(
      totalMemory:        heapSize,
      usedMemory:         used,
      freeMemory:         heapSize - used,
      blockCount:         _blocks.length,
      allocatedBlocks:    allocCount,
      freeBlocks:         freeCount,
      fragmentationRatio: frag,
      gcRunCount:         _gcRunCount,
      gcBytesCollected:   _gcBytesCollected,
    );
  }

  // ─── Virtual address translation ─────────────────────────────────────────

  /// Map a virtual address to its physical counterpart.
  ///
  /// In this implementation the kernel uses an identity map (VA == PA).
  Pointer virtualToPhysical(Pointer virtualAddr) => virtualAddr;

  /// Map a physical address to its virtual counterpart.
  Pointer physicalToVirtual(Pointer physicalAddr) => physicalAddr;

  // ─── Internal helpers ─────────────────────────────────────────────────────

  MemoryBlock? _firstFit(int size) {
    for (final b in _blocks) {
      if (!b.isAllocated && b.sizeBytes >= size) return b;
    }
    return null;
  }

  MemoryBlock? _bestFit(int size) {
    MemoryBlock? best;
    for (final b in _blocks) {
      if (!b.isAllocated && b.sizeBytes >= size) {
        if (best == null || b.sizeBytes < best.sizeBytes) best = b;
      }
    }
    return best;
  }

  MemoryBlock? _worstFit(int size) {
    MemoryBlock? worst;
    for (final b in _blocks) {
      if (!b.isAllocated && b.sizeBytes >= size) {
        if (worst == null || b.sizeBytes > worst.sizeBytes) worst = b;
      }
    }
    return worst;
  }

  /// Split [block] into an allocated part of [size] bytes and a free remainder.
  void _splitBlock(MemoryBlock block, int size) {
    final remainder = block.sizeBytes - size;
    if (remainder < alignment * 2) return; // Not worth splitting

    final newBlock = MemoryBlock(
      address:   block.address + size,
      sizeBytes: remainder,
    );
    block.sizeBytes = size;

    final idx = _blocks.indexOf(block);
    _blocks.insert(idx + 1, newBlock);
  }

  /// Merge adjacent free blocks to reduce fragmentation.
  void _coalesce() {
    var i = 0;
    while (i < _blocks.length - 1) {
      final curr = _blocks[i];
      final next = _blocks[i + 1];

      if (!curr.isAllocated && !next.isAllocated &&
          curr.endAddress == next.address) {
        curr.sizeBytes += next.sizeBytes;
        _blocks.removeAt(i + 1);
      } else {
        i++;
      }
    }
  }

  MemoryBlock? _blockAt(Pointer ptr) {
    for (final b in _blocks) {
      if (b.address == ptr) return b;
    }
    return null;
  }

  static int _alignUp(int value) =>
      (value + alignment - 1) & ~(alignment - 1);

  // ─── Debug ─────────────────────────────────────────────────────────────

  /// Dump all memory blocks to the logger (DEBUG level).
  @visibleForTesting
  void dumpBlocks() {
    _log.fine('=== Memory Block Dump ===');
    for (final b in _blocks) {
      _log.fine('  $b');
    }
    _log.fine('=========================');
  }
}
