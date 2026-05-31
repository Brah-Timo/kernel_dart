# Getting Started with kernel_dart

`kernel_dart` is an ultra-lightweight bare-metal OS kernel that runs Dart AOT-compiled
applications directly on hardware — no Linux, no RTOS.

---

## Prerequisites

| Tool | Minimum version | Notes |
|------|----------------|-------|
| Dart SDK | 3.0.0 | `dart --version` |
| GCC ARM cross-toolchain | any | `aarch64-linux-gnu-gcc` |
| QEMU | 7.x | for emulation; `qemu-system-aarch64` |
| Python 3 | 3.8+ | build scripts |

### Install cross-toolchain (Ubuntu / Debian)
```bash
sudo apt install gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf \
                 binutils-aarch64-linux-gnu qemu-system-arm
```

---

## Installation

Add `kernel_dart` to your `pubspec.yaml`:

```yaml
dependencies:
  kernel_dart: ^1.0.0
```

Or install the CLI tool globally:

```bash
dart pub global activate kernel_dart
```

---

## Quick Start — Raspberry Pi 3

### 1. Create a new project

```bash
kdart new my_kernel --platform raspberry_pi_3
cd my_kernel
```

This generates:

```
my_kernel/
├── pubspec.yaml
├── bin/
│   └── main.dart        ← kernel entry point
└── build/               ← created on first build
```

### 2. Write your kernel

```dart
// bin/main.dart
import 'package:kernel_dart/kernel_dart.dart';

void main() async {
  // Initialise the Raspberry Pi platform (auto-detects Pi 3 vs Pi 4)
  final pi = await RaspberryPiPlatform.init();

  pi.uart.println('Hello from Dart bare metal!');

  // Blink the activity LED 5 times
  await pi.gpio.blinkLED(47, times: 5);

  // Start the task scheduler
  final sched = TaskScheduler.instance;

  sched.addTask('heartbeat', () {
    pi.uart.println('tick');
  }, priority: 10);

  // Run forever
  while (true) {
    sched.tick();
  }
}
```

### 3. Build

```bash
kdart build --platform raspberry_pi_3 --arch arm64
```

Output: `build/kernel.bin`

### 4. Emulate with QEMU

```bash
kdart emulate --platform raspberry_pi_3 --image build/kernel.bin
```

### 5. Flash to SD card

```bash
kdart flash --device /dev/sdb --image build/kernel.bin
```

---

## Project Structure

```
project/
├── pubspec.yaml          ← declare kernel_dart dependency
├── bin/
│   └── main.dart         ← kernel entry point (void main())
├── lib/                  ← optional: kernel modules
├── native/               ← optional: C/Assembly startup code
│   ├── bootloader/
│   └── drivers/
├── build/                ← generated artefacts
│   ├── kernel.dill       ← Dart Kernel IR
│   ├── kernel.elf        ← native ELF
│   ├── kernel.bin        ← raw binary (flash this)
│   └── kernel.bin.gz     ← compressed (optional)
└── test/
```

---

## Supported Platforms

| Platform | Architecture | Boot method |
|----------|-------------|-------------|
| Raspberry Pi 3B/3B+ | AArch64 | U-Boot / raw SD |
| Raspberry Pi 4B | AArch64 | U-Boot / UEFI |
| Generic ARM64 | AArch64 | QEMU virt machine |
| Generic ARM32 | ARMv7-A | Multiboot2 / U-Boot |
| x86-64 | x86-64 | Multiboot2 (GRUB/QEMU) |
| x86-64 UEFI | x86-64 | UEFI EFI Application |
| STM32F4/H7 | Cortex-M | Bare-metal flash |
| ESP32 | Xtensa LX6 | esptool.py |

---

## Next Steps

- [Architecture Overview](architecture.md) — how the kernel works
- [API Reference](api_reference.md) — all public classes and methods
- [Driver Guide](drivers.md) — using UART, GPIO, I²C, SPI, Timer
- [Compiler Guide](compiler.md) — AOT compilation pipeline
- [Bootloader Guide](bootloader.md) — generating boot code
