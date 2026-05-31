# API Reference

Complete reference for all public classes and methods in `kernel_dart`.

---

## Compiler

### `DartCompiler`

Main compilation facade. Wraps `dart compile kernel` and `dart compile exe`.

```dart
DartCompiler({
  required String dartSdkPath,
  required TargetArchitecture architecture,
  CompilerOptions options = const CompilerOptions(),
})
```

| Method | Signature | Description |
|--------|-----------|-------------|
| `compileToKernel` | `Future<KernelBinary>` | Dart source → `.dill` Kernel IR |
| `compileToNative` | `Future<NativeBinary>` | `.dill` → native ELF |
| `crossCompile` | `Future<NativeBinary>` | Source → native for different arch |

### `TargetArchitecture`

```dart
enum TargetArchitecture { arm64, arm, x86_64, riscv64 }
```

Factory: `TargetArchitecture.fromString(String s)`

### `CompilerOptions`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `treeShake` | `bool` | `true` | Remove unused code |
| `inlining` | `bool` | `true` | Inline small functions |
| `lto` | `bool` | `true` | Link-time optimisation |
| `optimizationLevel` | `int` | `3` | 0–4 |
| `extraFlags` | `List<String>` | `[]` | Extra AOT flags |
| `defines` | `Map<String,String>` | `{}` | `-D key=value` defines |

Presets: `CompilerOptions.minSize()`, `CompilerOptions.maxPerformance()`

### `CompilationPipeline`

High-level pipeline: source → `.dill` → `.elf` → `.bin` → `.bin.gz`.

```dart
CompilationPipeline({required DartCompiler compiler, String buildDir = 'build'})
Future<String> run(String entryPoint, {bool optimize, bool strip, bool compress})
```

### `CrossCompiler`

Compiles for a target architecture different from the host.

```dart
CrossCompiler({
  required String dartSdkPath,
  required TargetArchitecture targetArch,
  CompilerOptions options,
})
Future<NativeBinary> compile({
  required String sourcePath,
  required String outputPath,
  bool singleBinary,
  String? linkerScript,
})
```

---

## Bootloader

### `ARMBootloader`

Generates AArch64 / ARMv7-A bootloader Assembly and linker scripts.

```dart
ARMBootloader({
  required TargetBoard targetBoard,
  int? memoryBaseAddress,
  int? kernelLoadAddress,
  bool aarch64 = true,
})
String generateBootloaderAsm()
String generateLinkerScript()
Future<void> writeFiles(String outputDir)
```

### `X86Bootloader`

Generates x86-64 Multiboot2 or UEFI stub Assembly and linker scripts.

```dart
X86Bootloader({
  X86BootMode bootMode = X86BootMode.multiboot2,
  int kernelLoadAddress = 0x100000,
  int stackSize = 0x10000,
})
String generateBootloaderAsm()
String generateLinkerScript()
Future<void> writeFiles(String outputDir)
```

### `UefiLoader`

Generates a PE32+ EFI Application C source for UEFI boot.

```dart
UefiLoader({UefiLoaderConfig config = const UefiLoaderConfig()})
String generateCSource()
String generateMakefile()
Future<void> writeFiles(String outputDir)
```

---

## Kernel

### `MemoryManager`

Singleton kernel heap allocator with mark-and-sweep GC.

```dart
// Initialise (call once at boot)
MemoryManager.init({
  required Pointer heapStart,
  required int heapSize,
  double gcThreshold = 0.1,
  AllocationStrategy strategy = AllocationStrategy.bestFit,
})

// Access singleton
MemoryManager.instance

// Allocation
Pointer allocate(int sizeBytes)
Pointer allocateZeroed(int count, int elementSize)
void deallocate(Pointer ptr)

// Reference counting
void retain(Pointer ptr)
void release(Pointer ptr)

// GC
int runGarbageCollection()  // returns bytes reclaimed

// Statistics
MemoryStats getMemoryStats()
```

### `TaskScheduler`

Singleton preemptive multi-task scheduler.

```dart
TaskScheduler.instance

Task addTask(String name, void Function() taskFunction, {
  int priority = 0, int stackSize = 8192,
})
void removeTask(int taskId)
void tick()                           // call from timer ISR
void sleepTask(Task task, Duration d)
void blockTask(Task task)
void unblockTask(Task task)
void sendMessage(Task task, Object message)
Object? receiveMessage({Task? fromTask})
SchedulerStats getStats()
```

### `InterruptHandler`

Dispatches hardware IRQs to registered driver handlers.

### `DeviceRegistry`

Central driver registry.

```dart
DeviceRegistry.instance

void register(DeviceDriver driver)
void unregister(String name)
T? get<T extends DeviceDriver>(String name)
List<T> getByType<T extends DeviceDriver>(DeviceType type)
Future<void> initAll()
Future<void> suspendAll()
Future<void> resumeAll()
String dumpStatus()
```

### `KernelApi`

High-level kernel façade combining memory, scheduler, drivers, and interrupts.

---

## Device Drivers

### `UARTDriver` (PL011)

```dart
UARTDriver({required int baseAddress, int baudRate = 115200, UARTConfig? config})

// TX
void putByte(int byte)
void putChar(int codeUnit, {bool crLfConvert = true})
void print(String message)
void println(String message)
void writeBytes(Uint8List bytes)
void printf(String format, List<Object> args)

// RX
int getByte()                         // blocks until data
int getByteTimeout(int timeoutMs)     // -1 on timeout
int? tryGetByte()                     // null if FIFO empty
Uint8List readBytes(int maxBytes)
String readLine({bool echo = false})
```

### `GPIODriver` (BCM2835)

```dart
GPIODriver({required int baseAddress})

void setDirection(int pin, GPIODirection direction)
void setFunction(int pin, GPIOFunction fn)
void writeLevel(int pin, GPIOLevel level)
void toggle(int pin)
GPIOLevel readLevel(int pin)
void setPull(int pin, GPIOPull pull)
void enableEdgeDetect(int pin, GPIOEdge edge)
void disableEdgeDetect(int pin)
void onEdge(int pin, void Function(GpioPinEvent) callback)
void clearEdgeListeners(int pin)
Future<void> blinkLED(int pin, {int times, Duration onDuration, Duration offDuration})
void writeBank0(int highMask, int lowMask)
```

### `I2CDriver` (BCM2835 BSC)

```dart
I2CDriver({required int baseAddress, I2CConfig? config})

I2CResult writeRaw(int deviceAddr, Uint8List data)
I2CResult readRaw(int deviceAddr, int length)
void writeByte(int deviceAddr, int reg, int value)
int readByte(int deviceAddr, int reg)
void writeWord(int deviceAddr, int reg, int word)
int readWord(int deviceAddr, int reg)
Uint8List readBytes(int deviceAddr, int reg, int length)
bool probeDevice(int deviceAddr)
List<int> scanBus()
int readInt16LE(int deviceAddr, int reg)
```

### `SPIDriver` (BCM2835 SPI0)

```dart
SPIDriver({required int baseAddress, SPIConfig? config})

Future<Uint8List> transfer(Uint8List txData)
Future<void> write(Uint8List data)
Future<int> transferByte(int byte)
Future<Uint8List> read(int length)
Future<void> writeRegister(int regAddr, int value)
Future<Uint8List> readRegisters(int regAddr, int length)
```

### `TimerDriver` (ARM SP804 + BCM2835)

```dart
TimerDriver({required int baseAddress, int clockHz = 1000000})

int get ticks
int get elapsedMs
int get elapsedUs
int readCounter64()
void delayMs(int ms)
void delayUs(int us)
void oneShot(Duration duration)
void stop()
SoftwareTimer scheduleTimer(String name, Duration interval, void Function() callback, {bool repeating})
void cancelTimer(SoftwareTimer t)
TimerStats getStats()
```

---

## Platform

### `RaspberryPiPlatform`

```dart
static Future<RaspberryPiPlatform> init({bool verbose = true})

UARTDriver uart
GPIODriver gpio
TimerDriver timer
I2CDriver i2c
SPIDriver spi
RaspberryPiModel model
RaspberryPiMailbox mailbox
int get activityLedPin
Future<void> blinkActivityLed({int times = 3})
void scanI2C()
```

### `PlatformConfig`

```dart
PlatformConfig.raspberryPi3
PlatformConfig.raspberryPi4
PlatformConfig.stm32f4
PlatformConfig.stm32h7
PlatformConfig.esp32
PlatformConfig.genericArm64

static PlatformConfig fromString(String name)
static PlatformConfig get current
static void setCurrent(PlatformConfig config)
```

---

## Emulator

### `QemuRunner`

```dart
// Build QEMU args from PlatformConfig
static List<String> buildArgs({
  required PlatformConfig platform,
  required String imagePath,
  int memoryMb = 256,
  bool debugMode = false,
  int gdbPort = 1234,
  bool noGraphic = true,
  List<String> extra = const [],
})

// Launch QEMU process
static Future<Process> launch(QemuConfig config)

// Check availability
static Future<bool> isAvailable(QemuMachine machine)
static Future<Map<String, String>> detectInstalledQemu()
```

---

## Utilities

### `CompressionUtils`

```dart
static Uint8List compressGzip(List<int> bytes, {int level = 6})
static List<int> decompressGzip(List<int> bytes)
static Future<String> compressFile(String inputPath, {String? outputPath, int level = 9})
static Future<String> decompressFile(String inputPath, {String? outputPath})
static Uint8List compressZlib(List<int> bytes, {int level = 6})
static List<int> decompressZlib(List<int> bytes)
static Uint8List decompressLz4Block(Uint8List src, int outputSize)
static int crc32(List<int> bytes)
static Future<int> crc32File(String path)
static int adler32(List<int> bytes)
static int fletcher16(List<int> bytes)
static double entropy(List<int> bytes)
static String hexDigest(int value, {int width = 8})
```

### `ElfParser`

```dart
ElfBinary? parse(Uint8List bytes)
```

`ElfBinary` exposes `header`, `programHeaders`, `sectionHeaders`, `loadSegments`,
`memoryFootprint`, `segmentBytes(ph)`.

### `ImageBuilder`

High-level image creation: links ELF sections into a flat binary, optionally
compresses, and reports image statistics.
