import 'package:kernel_dart/src/kernel/memory_manager.dart';
import 'package:test/test.dart';

void main() {
  // Reset singleton before each test group
  setUp(() => MemoryManager.init(heapStart: 0x100000, heapSize: 64 * 1024));

  group('MemoryManager.init', () {
    test('creates a singleton with correct heap bounds', () {
      final mm = MemoryManager.init(heapStart: 0x200000, heapSize: 128 * 1024);
      expect(mm.heapStart, equals(0x200000));
      expect(mm.heapSize, equals(128 * 1024));
    });

    test('instance getter returns the same object', () {
      final mm = MemoryManager.init(heapStart: 0x100000, heapSize: 64 * 1024);
      expect(MemoryManager.instance, same(mm));
    });
  });

  group('allocate / deallocate', () {
    late MemoryManager mm;
    setUp(() => mm = MemoryManager.init(heapStart: 0x100000, heapSize: 64 * 1024));

    test('allocate returns non-null pointer for valid size', () {
      final ptr = mm.allocate(256);
      expect(ptr, isNot(equals(nullPtr)));
    });

    test('allocate returns nullPtr for size 0', () {
      expect(mm.allocate(0), equals(nullPtr));
    });

    test('allocate returns nullPtr for negative size', () {
      expect(mm.allocate(-1), equals(nullPtr));
    });

    test('allocation pointer is within heap bounds', () {
      final ptr = mm.allocate(512);
      expect(ptr, greaterThanOrEqualTo(0x100000));
      expect(ptr, lessThan(0x100000 + 64 * 1024));
    });

    test('allocated pointer is 8-byte aligned', () {
      final ptr = mm.allocate(13); // odd size — must still be aligned
      expect(ptr % MemoryManager.alignment, equals(0));
    });

    test('multiple allocations return distinct pointers', () {
      final p1 = mm.allocate(64);
      final p2 = mm.allocate(64);
      final p3 = mm.allocate(64);
      expect(p1, isNot(equals(p2)));
      expect(p2, isNot(equals(p3)));
    });

    test('deallocate reduces used memory', () {
      final before = mm.getMemoryStats().usedMemory;
      final ptr = mm.allocate(1024);
      expect(mm.getMemoryStats().usedMemory, greaterThan(before));
      mm.deallocate(ptr);
      expect(mm.getMemoryStats().usedMemory, lessThanOrEqualTo(before));
    });

    test('deallocate nullPtr is a no-op', () {
      expect(() => mm.deallocate(nullPtr), returnsNormally);
    });

    test('can re-allocate after free', () {
      final ptr = mm.allocate(1024);
      mm.deallocate(ptr);
      final ptr2 = mm.allocate(1024);
      expect(ptr2, isNot(equals(nullPtr)));
    });
  });

  group('MemoryStats', () {
    late MemoryManager mm;
    setUp(() => mm = MemoryManager.init(heapStart: 0x100000, heapSize: 64 * 1024));

    test('totalMemory equals heapSize', () {
      expect(mm.getMemoryStats().totalMemory, equals(64 * 1024));
    });

    test('freeMemory + usedMemory == totalMemory', () {
      mm.allocate(1024);
      final s = mm.getMemoryStats();
      expect(s.freeMemory + s.usedMemory, equals(s.totalMemory));
    });

    test('allocatedBlocks increases on allocate', () {
      final before = mm.getMemoryStats().allocatedBlocks;
      mm.allocate(128);
      expect(mm.getMemoryStats().allocatedBlocks, greaterThan(before));
    });

    test('fragmentationRatio is 0–1', () {
      final ratio = mm.getMemoryStats().fragmentationRatio;
      expect(ratio, inInclusiveRange(0.0, 1.0));
    });
  });

  group('AllocationStrategy', () {
    test('firstFit initialises without error', () {
      final mm = MemoryManager.init(
        heapStart: 0x100000,
        heapSize:  32 * 1024,
        strategy:  AllocationStrategy.firstFit,
      );
      expect(mm.allocate(64), isNot(equals(nullPtr)));
    });

    test('bestFit initialises without error', () {
      final mm = MemoryManager.init(
        heapStart: 0x100000,
        heapSize:  32 * 1024,
        strategy:  AllocationStrategy.bestFit,
      );
      expect(mm.allocate(64), isNot(equals(nullPtr)));
    });

    test('worstFit initialises without error', () {
      final mm = MemoryManager.init(
        heapStart: 0x100000,
        heapSize:  32 * 1024,
        strategy:  AllocationStrategy.worstFit,
      );
      expect(mm.allocate(64), isNot(equals(nullPtr)));
    });
  });

  group('GC', () {
    test('runGarbageCollection does not throw', () {
      final mm = MemoryManager.init(heapStart: 0x100000, heapSize: 64 * 1024);
      expect(() => mm.runGarbageCollection(), returnsNormally);
    });

    test('gcRunCount increments after GC', () {
      final mm = MemoryManager.init(heapStart: 0x100000, heapSize: 64 * 1024);
      final before = mm.getMemoryStats().gcRunCount;
      mm.runGarbageCollection();
      expect(mm.getMemoryStats().gcRunCount, greaterThan(before));
    });
  });
}
