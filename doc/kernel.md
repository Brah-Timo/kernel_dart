# Kernel

The kernel subsystem provides the core OS services: memory management, task
scheduling, interrupt handling, and device management.

---

## Table of Contents

1. [MemoryManager](#memorymanager)
2. [TaskScheduler](#taskscheduler)
3. [InterruptHandler](#interrupthandler)
4. [DeviceRegistry and DriverBus](#deviceregistry-and-driverbus)
5. [KernelApi](#kernelapi)
6. [Memory Layout](#memory-layout)

---

## MemoryManager

`MemoryManager` implements a flat heap allocator over a contiguous physical
memory region. Three allocation algorithms are supported and selectable at
runtime.

### Initialisation

```dart
MemoryManager.init(
  heapStart: 0x248000,   // first byte of the heap
  heapSize:  0x3DB8000,  // 63.5 MB
);
```

`init` is a static method — there is a single global `MemoryManager.instance`.
The heap region **must not overlap** the kernel code/BSS/data sections.

### Allocation Algorithms

| Algorithm    | Description                                                         |
|--------------|---------------------------------------------------------------------|
| `firstFit`   | Walk free list, return the first block that fits (fast)             |
| `bestFit`    | Walk entire free list, return the smallest suitable block           |
| `worstFit`   | Walk entire free list, return the largest block (reduces large-alloc fragmentation) |

Switch at runtime:

```dart
MemoryManager.instance.algorithm = AllocationAlgorithm.bestFit;
```

### Allocation and Deallocation

```dart
final manager = MemoryManager.instance;

// Allocate 1 KiB block
final block = manager.allocate(1024);
// block.address  — uint32 physical address
// block.size     — actual allocated size (>= 1024, may be rounded up)

// Release
manager.free(block);

// Allocate with alignment (e.g. 4 KiB page-aligned)
final aligned = manager.allocateAligned(4096, alignment: 4096);
```

### GC-assisted Allocation

`MemoryManager` integrates with `GcHandler`. When `allocate` fails due to
exhaustion, it triggers a GC sweep and retries:

```dart
final block = manager.allocateWithGc(size);
```

### Heap Statistics

```dart
final stats = manager.stats();
print('free   : ${stats.freeBytes} B');
print('used   : ${stats.usedBytes} B');
print('frags  : ${stats.fragmentCount}');
print('peak   : ${stats.peakUsedBytes} B');
```

### Memory Protection

On platforms with an MMU (Cortex-A), `MemoryManager` can configure page-table
attributes for executable / read-only / device-mapped regions:

```dart
manager.protect(
  address:    0x3F000000,   // BCM2835 peripheral base
  size:       0x01000000,   // 16 MB
  protection: MemoryProtection.deviceNcnb, // Non-cacheable, non-bufferable
);
```

---

## TaskScheduler

`TaskScheduler` implements preemptive multi-task scheduling with priority queues
and round-robin within each priority class.

### Scheduler Policies

| Policy        | Description                                          |
|---------------|------------------------------------------------------|
| `priority`    | Higher-priority tasks always preempt lower ones      |
| `roundRobin`  | Tasks of equal priority share CPU time equally       |
| `cfs`         | Completely Fair Scheduler — tracks virtual runtime   |

### Creating Tasks

```dart
final scheduler = TaskScheduler.instance;

final taskId = scheduler.createTask(
  name:      'blink',
  priority:  100,
  function:  () { gpio.toggle(17); },
  stackSize: 4096,
);
```

### Task Lifecycle

```dart
scheduler.wakeUp(taskId);          // sleeping -> ready
scheduler.sleep(taskId, duration); // park until duration elapses
scheduler.terminate(taskId);       // mark as terminated
scheduler.yield();                 // voluntarily yield the CPU
```

### Tick-driven Scheduling

The scheduler is driven by a hardware timer IRQ. Each tick:

1. Decrements the running task's remaining time slice
2. If slice exhausted → adds to tail of its priority queue → selects next
3. Wakes sleeping tasks whose wake time ≤ current tick

```dart
// Called from the timer ISR:
scheduler.tick();
```

### Inter-Task Messaging

Tasks communicate via a simple mailbox model:

```dart
// Send
scheduler.send(receiverTaskId, payload: {'key': 'value'});

// Receive (blocks until a message arrives)
final msg = await scheduler.receive();
print(msg.payload);
```

### Scheduler Statistics

```dart
final s = scheduler.stats();
print('context switches : ${s.contextSwitches}');
print('active tasks     : ${s.activeTaskCount}');
print('idle ticks       : ${s.idleTicks}');
```

### Task

```dart
final class Task {
  final int    id;
  final String name;
  int          priority;
  TaskState    state;      // ready | running | sleeping | blocked | terminated
  int          stackPointer;
  Duration?    wakeTime;
}
```

---

## InterruptHandler

`InterruptHandler` manages a vector table of IRQ callbacks and dispatches
hardware interrupts to registered drivers.

### Registering Handlers

```dart
final irq = InterruptHandler.instance;

// Register a raw IRQ handler
irq.register(
  vector:   65,    // IRQ 65 = UART0 on BCM2835
  handler:  (int vector) { uart.handleIrq(vector); },
  priority: IrqPriority.normal,
);

// Register a driver directly (uses driver.info.irqNumber)
irq.registerDriver(uart);
```

### Enabling / Disabling

```dart
irq.enable(65);
irq.disable(65);
irq.enableAll();
irq.disableAll();  // critical section
```

### ARM GIC Integration

On Cortex-A boards with a Generic Interrupt Controller:

```dart
irq.initGic(
  distributor:  0x08000000,  // GIC distributor base
  cpuInterface: 0x08010000,  // GIC CPU interface base
);
```

### IRQ Priorities

```dart
enum IrqPriority {
  critical,   // Hardware faults (highest)
  high,       // Timer, DMA
  normal,     // UART, GPIO, I2C, SPI
  low,        // Background tasks
}
```

---

## DeviceRegistry and DriverBus

### DeviceRegistry

Singleton registry of all instantiated device drivers.

```dart
final reg = DeviceRegistry.instance;

// Register
reg.register(uartDriver);
reg.register(gpioDriver);

// Look up by name
final uart = reg.find('uart0') as UARTDriver?;

// Look up by type
final gpios = reg.findByType(DeviceType.gpio);

// Iterate all drivers
for (final driver in reg.drivers) {
  print('${driver.info.name}: ${driver.status}');
}
```

### DeviceDriver Base Class

```dart
abstract class DeviceDriver {
  DeviceInfo   get info;
  DeviceStatus status;

  Future<void> init();
  Future<void> cleanup();
  void         handleIrq(int irqNumber);
  int          readRegister(int offset);
  void         writeRegister(int offset, int value);
}
```

### DeviceInfo

```dart
final class DeviceInfo {
  final String     name;
  final String     description;
  final DeviceType type;       // uart | gpio | i2c | spi | timer | …
  final int        baseAddress;
  final int        irqNumber;
}
```

### DeviceStatus

```dart
enum DeviceStatus { uninitialised, initialising, ready, error, removed }
```

---

## KernelApi

`KernelApi` is the high-level façade that integrates all kernel subsystems and
provides the single `boot()` entry point called by the bootloader.

### Boot Entry Point

```dart
// Called by the bootloader Assembly with BootInfo* in x0/r0:
KernelApi.boot(bootInfo);
```

`boot()` in order:

1. Parses `BootInfo` struct
2. Initialises `MemoryManager` from the memory map
3. Configures early UART
4. Starts `InterruptHandler` (enables GIC)
5. Initialises `TaskScheduler`
6. Registers built-in drivers (UART, GPIO, Timer, I2C, SPI)
7. Calls the user's `kernelMain()` function
8. Enters the scheduler event loop

---

## Memory Layout

Default memory layout for Raspberry Pi 3 (1 GB RAM):

```
0x00000000 ┌──────────────────────────────┐
           │  Firmware / GPU RAM (< 1 MB) │
0x00080000 ├──────────────────────────────┤ <- kernelLoadAddress
           │  Dart kernel (AOT binary)    │  ~2 MB typical
0x00280000 ├──────────────────────────────┤
           │  Stack (grows down)   64 KB  │
0x00290000 ├──────────────────────────────┤
           │  BootInfo struct       4 KB  │
0x00300000 ├──────────────────────────────┤ <- heapStart
           │                              │
           │  Dart Heap (MemoryManager)   │
           │  ~996 MB usable              │
           │                              │
0x3F000000 ├──────────────────────────────┤ <- BCM2835 peripheral bus
           │  MMIO registers   (16 MB)    │
0x40000000 └──────────────────────────────┘
```

> For Raspberry Pi 4 the peripheral bus moves to `0xFE000000` and RAM extends
> to `0x100000000` (4 GB on the 4B 4 GB model).
