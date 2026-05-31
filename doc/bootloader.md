# Bootloader

`kernel_dart` generates ARM/AArch64 and x86-64 bootloader Assembly and linker
scripts at runtime from Dart code — no hard-coded binary blobs required.

---

## Table of Contents

1. [Overview](#overview)
2. [ARMBootloader](#armbootloader)
3. [X86Bootloader](#x86bootloader)
4. [UefiLoader](#uefiloader)
5. [BootProtocol](#bootprotocol)
6. [Boot Sequences](#boot-sequences)

---

## Overview

```
DartCompiler compiles your kernel →  kernel.elf
                                          |
          ┌────────────────────────────────┘
          |
   ARMBootloader.writeFiles()
          |
          ├── startup_arm64.S   (Assembly source, generated)
          └── linker_arm64.ld   (GNU LD linker script, generated)
                    |
                    v  (user assembles + links)
                boot.elf  →  objcopy  →  kernel.bin  (flashable)
```

The `kdart build` command orchestrates the entire process automatically.

---

## ARMBootloader

Generates AArch64 (default) or ARMv7-A 32-bit startup code.

### Constructor

```dart
ARMBootloader({
  required TargetBoard targetBoard,
  int? memoryBaseAddress,   // defaults to targetBoard.stackTop
  int? kernelLoadAddress,   // defaults to targetBoard.kernelLoad
  bool aarch64 = true,
})
```

### TargetBoard Presets

| Board          | CPU        | RAM base   | Kernel load | UART base  |
|----------------|------------|------------|-------------|------------|
| `raspberryPi3` | Cortex-A53 | 0x00000000 | 0x00080000  | 0x3F201000 |
| `raspberryPi4` | Cortex-A72 | 0x00000000 | 0x00080000  | 0xFE201000 |
| `genericArm64` | Cortex-A   | 0x40000000 | 0x40080000  | 0x09000000 |
| `genericArm32` | Cortex-A7  | 0x80000000 | 0x80080000  | 0x01C28000 |

### Generated AArch64 Boot Sequence

1. `MSR DAIFSet, #0xF` — disable all IRQs and FIQs
2. Park secondary cores (1–3) in WFE spin loop
3. Set `SP_EL1` to `stackTop`
4. Zero-clear BSS (`__bss_start` … `__bss_end`)
5. Initialise PL011 UART for early debug output
6. Build `BootInfo` struct in RAM; store pointer in `x0`
7. Branch to `dart_kernel_main`

### Methods

```dart
String generateBootloaderAsm()              // returns .S file contents
String generateLinkerScript()               // returns .ld file contents
Future<void> writeFiles(String outputDir)   // writes both files to disk
```

### Example

```dart
final bl = ARMBootloader(
  targetBoard:       TargetBoard.raspberryPi3,
  kernelLoadAddress: 0x80000,
  aarch64:           true,
);
await bl.writeFiles('build/bootloader/');
```

---

## X86Bootloader

Targets x86-64 with two boot modes:

| Mode         | Description                                              |
|--------------|----------------------------------------------------------|
| `multiboot2` | Legacy BIOS boot via GRUB / QEMU `-kernel` flag          |
| `uefi`       | UEFI PE32+ application stub                              |

### Constructor

```dart
X86Bootloader({
  X86BootMode bootMode          = X86BootMode.multiboot2,
  int kernelLoadAddress         = 0x100000,
  int stackSize                 = 0x10000,
})
```

### Multiboot2 Boot Sequence

1. Multiboot2 header in `.multiboot` section (magic `0xE85250D6`)
2. `_start32` — 32-bit protected mode entry
3. Load 32-bit GDT, enable PAE, build identity page tables (2 MB huge pages)
4. Enable long mode (LME in EFER MSR), enable paging
5. Long-jump to `._start64`
6. Reload 64-bit GDT, set up 64-bit stack, clear BSS, enable SSE/SSE2
7. Call `boot_init_x86(rdi = multiboot2_info)`

### Methods

```dart
String generateBootloaderAsm()
String generateLinkerScript()
Future<void> writeFiles(String outputDir)
```

### Example

```dart
final bl = X86Bootloader(bootMode: X86BootMode.multiboot2);
await bl.writeFiles('build/bootloader/');
// Boot with QEMU:
// qemu-system-x86_64 -kernel build/kernel.bin -nographic -serial stdio
```

---

## UefiLoader

`UefiLoader` generates a PE32+ EFI application that boots the Dart kernel under
UEFI firmware.

### Constructor

```dart
UefiLoader({
  required String efiLoadPath,     // e.g. '\\EFI\\BOOT\\kernel.bin'
  int kernelLoadAddress = 0x100000,
  bool verbose = true,
})
```

### Methods

```dart
Future<String> generateEfiStub()           // C source for the EFI application
Future<void>   writeFiles(String outputDir)
```

### Build Chain

```bash
UefiLoader.writeFiles('build/uefi/')
# Then:
x86_64-w64-mingw32-gcc -nostdlib -Wl,--subsystem,10 \
    -T build/uefi/linker_x86_uefi.ld \
    build/uefi/efi_main.c -o BOOTX64.EFI
# Copy BOOTX64.EFI to ESP: /EFI/BOOT/BOOTX64.EFI
```

---

## BootProtocol

Defines the in-memory structure shared between bootloader Assembly and the Dart
kernel.

### BootInfo

```dart
final class BootInfo {
  final int magic;          // 0xB007DA12 — 'BOOTDART'
  final int kernelBase;
  final int kernelSize;
  final int ramBase;
  final int ramSize;
  final int dtbPointer;     // Device-tree blob (0 if none)
  final int uartBase;
  final BootArchitecture arch;
  final List<MemoryRegion> memoryMap;
}
```

The bootloader builds this struct just below the kernel and passes its address
in register `x0` / `r0` on entry to `dart_kernel_main`.

### BootArchitecture

```dart
enum BootArchitecture { arm32, arm64, x86_64, riscv64 }
```

---

## Boot Sequences

### AArch64 (Raspberry Pi 3)

```
GPU firmware (start.elf)
  └─> loads kernel8.img at 0x80000, x0 = DTB pointer
        └─> _start  (bootloader Assembly)
              ├ mask IRQs/FIQs
              ├ park CPUs 1-3
              ├ init SP, clear BSS
              ├ PL011 UART early init
              └─> dart_kernel_main(x0 = BootInfo*)
                    └─> KernelApi.boot()
```

### x86-64 Multiboot2 (QEMU / GRUB)

```
BIOS / QEMU
  └─> GRUB verifies Multiboot2 header, loads kernel
        └─> _start32  (32-bit protected mode)
              ├ GDT, PAE, page tables
              ├ enable long mode + paging
              └─> ._start64
                    ├ GDT64, stack, BSS clear, SSE
                    └─> boot_init_x86(rdi = MB2 info)
                          └─> dart_kernel_main(x0 = BootInfo*)
                                └─> KernelApi.boot()
```

---

## CLI Usage

```bash
# Generate ARM64 bootloader files
kdart build --arch arm64 --platform rpi3 --output build/kernel.bin

# Build x86-64 Multiboot2 image
kdart build --arch x86_64 --boot multiboot2 --output build/kernel.bin

# Full compress + header
kdart build --arch arm64 --platform rpi3 --output build/kernel.bin --compress
```
