# Runtime

The runtime subsystem bridges the Dart AOT binary and the bare-metal hardware:
heap GC, exception handling, FFI/MMIO register access, and DMA control.

---

## Table of Contents

1. [DartRuntime](#dartruntime)
2. [GcHandler](#gchandler)
3. [ExceptionHandler](#exceptionhandler)
4. [FfiBridge and MMIO](#ffibridge-and-mmio)
5. [DmaController](#dmacontroller)
6. [CPU Utilities](#cpu-utilities)

---

## DartRuntime

`DartRuntime` is the top-level coordinator that bootstraps the Dart AOT runtime
environment on bare metal.

### Initialisation Sequence

```dart
DartRuntime.init(bootInfo);
```

Steps performed by `init`:

1. Configures the Dart heap base address and size from `BootInfo`
2. Installs the exception handler (synchronous faults → Dart exceptions)
3. Installs the GC handler (heap exhaustion → mark-and-sweep)
4. Registers the MMIO write-barrier (for device register writes)
5. Initialises the FFI bridge (function pointer table)
6. Enables the floating-point unit (NEON / SSE2)

### Key Properties

```dart
abstract final class DartRuntime {
  static bool get isInitialised;

  /// Physical base address of the Dart AOT heap.
  static int get heapBase;

  /// Total heap size in bytes.
  static int get heapSize;

  /// Dart SDK version string embedded in the AOT snapshot.
  static String get sdkVersion;

  /// Number of milliseconds since `DartRuntime.init` was called.
  static int get uptimeMs;
}
```

---

## GcHandler

`GcHandler` implements a conservative mark-and-sweep garbage collector tuned for
embedded systems with deterministic pause budgets.

### Configuration

```dart
GcHandler.configure(
  maxPauseMs:    5,       // Maximum GC pause in milliseconds
  gcThreshold:   0.75,    // Trigger GC when heap is 75% full
  incrementalGc: true,    // Spread GC work across multiple ticks
);
```

### Manual GC

```dart
GcHandler.collect();           // Full synchronous GC
GcHandler.collectAsync();      // Schedule GC on next idle tick
```

### GC Statistics

```dart
final stats = GcHandler.stats();
print('collections   : ${stats.collectionCount}');
print('freed bytes   : ${stats.totalBytesFreed}');
print('max pause ms  : ${stats.maxPauseMs}');
print('avg pause ms  : ${stats.avgPauseMs}');
```

### GC Events

Register a callback to be notified on every collection:

```dart
GcHandler.onCollect((GcStats stats) {
  _log.fine('GC: freed ${stats.lastBytesFreed} B in ${stats.lastPauseMs} ms');
});
```

### Heap Walking

```dart
GcHandler.walkHeap((HeapObject obj) {
  print('0x${obj.address.toRadixString(16)}: ${obj.type} (${obj.size} B)');
});
```

---

## ExceptionHandler

`ExceptionHandler` catches CPU exceptions (faults) and converts them to Dart
exceptions with full stack traces.

### Handled Faults

| Fault                       | Dart exception thrown          |
|-----------------------------|--------------------------------|
| Null pointer dereference    | `NullPointerException`         |
| Stack overflow              | `StackOverflowException`       |
| Division by zero            | `IntegerDivisionByZeroException`|
| Undefined instruction       | `IllegalInstructionException`  |
| Bus error / alignment fault | `BusErrorException`            |
| Prefetch abort              | `InstructionFetchException`    |

### Custom Fault Handlers

```dart
ExceptionHandler.register(
  FaultType.stackOverflow,
  (FaultInfo info) {
    _log.severe('Stack overflow at PC=0x${info.pc.toRadixString(16)}');
    // attempt recovery or reset
  },
);
```

### FaultInfo

```dart
final class FaultInfo {
  final FaultType type;
  final int       pc;       // Program Counter at fault
  final int       sp;       // Stack Pointer at fault
  final int       lr;       // Link Register (return address)
  final int?      faultAddress; // For data aborts: the bad address
}
```

### Panic Mode

If an unrecoverable fault occurs, `ExceptionHandler` enters panic mode:

1. Prints a crash dump over UART
2. Blinks the activity LED in an SOS pattern
3. Halts the CPU in an infinite loop

```dart
ExceptionHandler.panic('Out of memory — cannot recover');
```

---

## FfiBridge and MMIO

### MMIO

`MMIO` provides safe, typed access to memory-mapped I/O registers.

All MMIO accesses are **volatile** — the compiler will not cache or reorder them.

```dart
// 32-bit register read
final value = MMIO.read32(0x3F200000 + 0x34); // GPIO level register

// 32-bit register write
MMIO.write32(0x3F200000 + 0x1C, 1 << 17);     // Set GPIO 17 high

// Atomic set bits (read-modify-write)
MMIO.setBits(0x3F200000 + 0x4C, 1 << 17);     // Set GPIO 17 rising-edge detect

// Atomic clear bits
MMIO.clearBits(0x3F200000 + 0x4C, 1 << 17);

// Read-modify-write with callback
MMIO.modify32(baseAddr + offset, (v) => (v & ~mask) | newBits);

// 8-bit and 16-bit variants
final byte = MMIO.read8(addr);
MMIO.write16(addr, 0xABCD);
```

### CPU

`CPU` provides bare-metal CPU control primitives:

```dart
CPU.nop();            // No-operation (one cycle wait)
CPU.dmb();            // Data Memory Barrier (full ordering)
CPU.dsb();            // Data Synchronisation Barrier
CPU.isb();            // Instruction Synchronisation Barrier
CPU.wfi();            // Wait For Interrupt (low-power halt)
CPU.wfe();            // Wait For Event (secondary core park)
CPU.sev();            // Send Event (wake secondary cores)
CPU.enableIrq();      // Global IRQ enable (DAIF clear)
CPU.disableIrq();     // Global IRQ disable (DAIF set)
```

### FfiBridge

`FfiBridge` manages the function pointer dispatch table between the Dart runtime
and native C/Assembly helpers.

```dart
// Register a native function by name
FfiBridge.register('uart_putchar', nativeUartPutchar);

// Call a registered function
FfiBridge.call('uart_putchar', [0x41]); // 'A'
```

`FfiBridge` is also used internally by the MMIO layer to perform volatile
register accesses without Dart's optimizer interfering.

---

## DmaController

`DmaController` provides a Dart API for the BCM2835 DMA engine, enabling
zero-copy bulk data transfers between peripherals and memory.

### Channels

BCM2835 has 16 DMA channels (0–15). Channels 0–6 support 2D transfers;
channels 7–15 are "lite" channels with reduced capability.

```dart
final dma = DmaController(baseAddress: 0x3F007000);
await dma.init();

// Allocate a DMA channel
final ch = await dma.allocateChannel(); // returns 0–15
```

### Memory-to-Memory Transfer

```dart
await dma.transfer(
  channel:     ch,
  source:      srcPhysAddr,
  destination: dstPhysAddr,
  length:       1024,       // bytes
  sourceIncrement:      true,
  destinationIncrement: true,
);
```

### Peripheral Transfers

```dart
// Write from memory to SPI FIFO
await dma.transfer(
  channel:              ch,
  source:               txBufferPhysAddr,
  destination:          0x3F204004,  // BCM2835 SPI0 FIFO
  length:               txData.length,
  sourceIncrement:      true,
  destinationIncrement: false,  // peripheral register — no increment
  permap:               DreqPeripheral.spi0Tx,
);
```

### DreqPeripheral

```dart
enum DreqPeripheral {
  none,
  dsi,
  pcmTx,
  pcmRx,
  smi,
  pwm,
  spi0Tx,
  spi0Rx,
  bscSlaveTx,
  bscSlaveRx,
  unused,
  emmc,
  uartTx,
  sdHost,
  uartRx,
  dslModem,
  hdmi,
  slimbusMctl,
  hdmiPixel,
}
```

### DMA Completion

Transfers are asynchronous. `transfer()` returns a `Future` that completes when
the DMA engine asserts the `END` interrupt:

```dart
await dma.transfer(...);
// DMA complete — safe to read destination buffer
```

Or use the interrupt-based API:

```dart
dma.onComplete(ch, (DmaResult result) {
  print('DMA ch$ch done: ${result.bytesTransferred} bytes');
});
dma.startTransfer(ch, src, dst, length);
```

---

## Quick Reference

| Class             | Key methods                                           |
|-------------------|-------------------------------------------------------|
| `DartRuntime`     | `init()`, `heapBase`, `heapSize`, `uptimeMs`          |
| `GcHandler`       | `collect()`, `configure()`, `stats()`, `onCollect()`  |
| `ExceptionHandler`| `register()`, `panic()`, `FaultInfo`                  |
| `MMIO`            | `read32()`, `write32()`, `setBits()`, `modify32()`    |
| `CPU`             | `nop()`, `wfi()`, `dmb()`, `enableIrq()`              |
| `FfiBridge`       | `register()`, `call()`                                |
| `DmaController`   | `transfer()`, `allocateChannel()`, `onComplete()`     |
