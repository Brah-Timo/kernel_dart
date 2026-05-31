# kernel_dart 🦾

> **A revolutionary ultra-lightweight embedded OS kernel (~2 MB) written in Dart.**  
> Run Dart AOT-compiled applications directly on bare-metal hardware — no Linux, no RTOS, no overhead.

---

## Table of Contents

1. [Overview](#overview)
2. [Why kernel_dart?](#why-kernel_dart)
3. [Architecture](#architecture)
4. [Supported Platforms](#supported-platforms)
5. [Getting Started](#getting-started)
6. [CLI Reference](#cli-reference)
7. [Project Structure](#project-structure)
8. [Memory Layout](#memory-layout)
9. [Examples](#examples)
10. [Driver Development](#driver-development)
11. [Building from Source](#building-from-source)
12. [Roadmap](#roadmap)
13. [Contributing](#contributing)
14. [License](#license)

---

## Overview

**kernel_dart** bridges Dart with the world of bare-metal and embedded computing.  
Instead of the traditional stack:

```
[Application] → [Runtime] → [OS Kernel] → [Hardware]
```

kernel_dart collapses everything into a single 2 MB bootable image:

```
[Dart AOT Binary + Microkernel] → [Hardware]
```

Key numbers at a glance:

| Metric               | Traditional Linux | kernel_dart   |
|----------------------|-------------------|---------------|
| Disk footprint       | 300 MB+           | **~2 MB**     |
| Boot time            | 30 s – 2 min      | **100–300 ms**|
| RAM (idle)           | 50 MB+            | **< 4 MB**    |
| Attack surface       | Large             | **Minimal**   |

---

## Why kernel_dart?

| Pain point with traditional approach | kernel_dart solution                     |
|--------------------------------------|------------------------------------------|
| Full OS required (hundreds of MB)    | Microkernel + Dart runtime in 2 MB       |
| Slow boot (30 s+)                    | Direct hardware boot in < 300 ms         |
| No direct hardware access            | Full memory-mapped I/O, GPIO, UART, I2C  |
| Large attack surface                 | Minimal TCB; Dart type-safety included   |
| Complex toolchain                    | Single CLI: `kernel_dart build/flash/run`|

---

## Architecture

```
┌──────────────────────────────────────────────┐
│  Dart Application Code                       │
│  (IoT logic, controllers, servers …)        │
└────────────────────┬─────────────────────────┘
                     │
┌────────────────────▼─────────────────────────┐
│  Dart Runtime Library                        │
│  (Collections, async, isolates, FFI)        │
└────────────────────┬─────────────────────────┘
                     │
┌────────────────────▼─────────────────────────┐
│  kernel_dart Core Libraries                  │
│  GPIO · UART · I²C · SPI · Timer · Network  │
└────────────────────┬─────────────────────────┘
                     │
┌────────────────────▼─────────────────────────┐
│  Microkernel  (512 KB)                       │
│  Memory Manager · Scheduler · IRQ Handler   │
│  Device Driver Framework · IPC              │
└────────────────────┬─────────────────────────┘
                     │
┌────────────────────▼─────────────────────────┐
│  Hardware Abstraction Layer (HAL)            │
│  ARM CPU · MMU · GIC · AXI/APB Bus          │
└────────────────────┬─────────────────────────┘
                     │
┌────────────────────▼─────────────────────────┐
│  Bootloader  (32 KB)                         │
│  CPU init · Memory setup · Image decompress │
└────────────────────┬─────────────────────────┘
                     │
                  ⬛ Hardware
```

---

## Supported Platforms

| Platform         | Architecture | Status      |
|------------------|--------------|-------------|
| Raspberry Pi 3/4 | ARM Cortex-A | ✅ Supported |
| Raspberry Pi Zero| ARM Cortex-A | ✅ Supported |
| STM32F4          | ARM Cortex-M | 🔄 Beta      |
| STM32H7          | ARM Cortex-M | 🔄 Beta      |
| ESP32            | Xtensa LX6   | 🔄 Beta      |
| Generic ARM      | ARMv7/ARMv8  | ✅ Supported |
| x86-64 (QEMU)    | x86-64       | 🧪 Experimental|
| RISC-V           | RV64GC       | 📅 Planned   |

---

## Getting Started

### Prerequisites

```bash
# Install Dart SDK (>= 3.0.0)
brew install dart          # macOS
sudo apt install dart      # Ubuntu/Debian

# Install cross-compilation toolchain
sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu

# Install QEMU for emulation
sudo apt install qemu-system-arm
```

### Install kernel_dart CLI

```bash
dart pub global activate kernel_dart
```

### Quick Start

```bash
# Create a new bare-metal Dart project
kernel_dart new my_app --platform raspberry_pi

cd my_app

# Build bootable image
kernel_dart build --target arm64

# Flash to SD card
kernel_dart flash --device /dev/sdb

# OR run in QEMU emulator
kernel_dart emulate --platform raspberry_pi
```

---

## CLI Reference

```
kernel_dart <command> [options]

Commands:
  new          Create a new kernel_dart project
  build        Compile and link a bootable image
  flash        Write image to a physical device
  emulate      Run image in QEMU
  clean        Remove build artifacts
  info         Show platform and memory information
  doctor       Check toolchain and dependencies

Global options:
  --verbose, -v      Verbose output
  --help,    -h      Show help
  --version          Show version

build options:
  --target <arch>    Target architecture: arm64|arm|x86_64  (default: arm64)
  --platform <name>  Target board: raspberry_pi|stm32|esp32|generic_arm
  --output  <file>   Output binary path                     (default: build/kernel.bin)
  --optimize         Enable AOT optimizations               (default: true)
  --strip            Strip debug symbols
  --compress         Compress final image with gzip         (default: true)

flash options:
  --device  <path>   Block device path, e.g. /dev/sdb
  --offset  <bytes>  Write offset in bytes                  (default: 0)

emulate options:
  --platform <name>  Board to emulate
  --memory   <MB>    RAM size in MB                         (default: 512)
  --debug            Start GDB server on port 1234
```

---

## Project Structure

```
kernel_dart/
├── bin/
│   ├── kernel_dart.dart          # Main executable entry point
│   └── cli.dart                  # Full CLI implementation
├── lib/
│   ├── kernel_dart.dart          # Public library barrel
│   └── src/
│       ├── compiler/             # Dart → AOT compilation pipeline
│       ├── bootloader/           # Bootloader generators (ARM/x86/UEFI)
│       ├── kernel/               # Microkernel (memory, scheduler, IRQ)
│       ├── runtime/              # Dart runtime + GC + FFI bridge
│       ├── drivers/              # UART, GPIO, Timer, SPI, I2C
│       ├── utils/                # Image builder, ELF parser, hex tools
│       ├── config/               # Platform config, memory layout
│       └── platform/             # Board-specific support files
├── native/                       # C/Assembly low-level code
│   ├── bootloader/               # startup_arm.S, startup_x86.S, linker.ld
│   ├── kernel/                   # context_switch.S, memory.c, interrupts.c
│   └── drivers/                  # uart.c, timer.c
├── example/                      # Runnable bare-metal examples
├── test/                         # Unit tests
├── doc/                          # Detailed documentation
├── scripts/                      # Build, flash, CI scripts
└── tools/                        # QEMU runner, GDB wrapper, profiler
```

---

## Memory Layout

```
0x00000000  ┌─────────────────────────────────┐
            │ Bootloader           (32 KB)     │
0x00008000  ├─────────────────────────────────┤
            │ Kernel Code & Data  (512 KB)     │
0x00088000  ├─────────────────────────────────┤
            │ Dart Runtime        (512 KB)     │
0x00108000  ├─────────────────────────────────┤
            │ Device Drivers      (384 KB)     │
0x00168000  ├─────────────────────────────────┤
            │ App Code (AOT Dart) (512 KB)     │
0x001E8000  ├─────────────────────────────────┤
            │ Read-Only Data (rodata)          │
0x00208000  ├─────────────────────────────────┤
            │ Initialized Global Data          │
0x00228000  ├─────────────────────────────────┤
            │ BSS  (zero-initialized)          │
0x00248000  ├─────────────────────────────────┤
            │ Heap  (grows ↑)                  │
0x10000000  ├─────────────────────────────────┤
            │ Memory-Mapped I/O                │
            │ (UART, GPIO, Timer, I2C, SPI)   │
0xFFFFFFFF  └─────────────────────────────────┘
```

---

## Examples

### Hello World

```dart
import 'package:kernel_dart/kernel_dart.dart';

void main() {
  final uart = UARTDriver(baseAddress: 0x09000000, baudRate: 115200);
  uart.print('Hello from Dart Bare Metal!\r\n');

  final stats = MemoryManager.instance.getMemoryStats();
  uart.print('Free RAM: ${stats.freeMemory} bytes\r\n');

  while (true) {} // spin
}
```

### Blink LED

```dart
import 'package:kernel_dart/kernel_dart.dart';

void main() {
  final gpio = GPIODriver(baseAddress: PlatformConfig.raspberryPi.gpioBase);
  const ledPin = 17;

  gpio.setDirection(ledPin, GPIODirection.output);

  while (true) {
    gpio.writeLevel(ledPin, GPIOLevel.high);
    BusyWait.milliseconds(500);
    gpio.writeLevel(ledPin, GPIOLevel.low);
    BusyWait.milliseconds(500);
  }
}
```

### I²C Sensor Read

```dart
import 'package:kernel_dart/kernel_dart.dart';

void main() {
  final uart = UARTDriver(baseAddress: 0x09000000, baudRate: 115200);
  final i2c  = I2CDriver(baseAddress: PlatformConfig.raspberryPi.i2cBase);

  const bmp280Addr = 0x76;
  final chipId = i2c.readByte(bmp280Addr, 0xD0);
  uart.print('BMP280 chip ID: 0x${chipId.toRadixString(16)}\r\n');

  while (true) {
    final raw = i2c.readWord(bmp280Addr, 0xFA);
    final temp = (raw >> 4) / 100.0;
    uart.print('Temp: ${temp.toStringAsFixed(2)} °C\r\n');
    BusyWait.seconds(1);
  }
}
```

---

## Building from Source

```bash
git clone https://github.com/your-org/kernel_dart.git
cd kernel_dart
dart pub get
dart run bin/cli.dart doctor        # check toolchain
dart run bin/cli.dart build --target arm64 --platform raspberry_pi
```

---

## Roadmap

- [x] ARM64 bootloader generator
- [x] Microkernel (memory manager, scheduler, IRQ handler)
- [x] UART, GPIO, Timer, SPI, I2C drivers
- [x] Raspberry Pi & generic ARM platform support
- [x] QEMU emulation runner
- [ ] RISC-V support
- [ ] LittleFS lightweight filesystem
- [ ] TCP/IP network stack
- [ ] Secure boot + image signing
- [ ] OTA firmware update
- [ ] GDB JTAG debugging integration

---

## Contributing

PRs are welcome! Please read [CONTRIBUTING.md](doc/CONTRIBUTING.md) first.

1. Fork the repo
2. Create a feature branch (`git checkout -b feat/my-feature`)
3. Commit changes (`git commit -m 'feat: add my feature'`)
4. Push and open a Pull Request

---

## License

MIT © 2026 kernel_dart contributors. See [LICENSE](LICENSE).
