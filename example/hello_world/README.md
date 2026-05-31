# hello_world

> **kernel_dart example** — the classic "Hello, World!" for bare-metal Dart.

Prints a banner and memory statistics over UART (PL011 at 115 200 baud), then
spins in an idle loop — exactly what a microkernel does before handing control
to user tasks.

## Target

| Field       | Value                                      |
|-------------|--------------------------------------------|
| Board       | Raspberry Pi 3 Model B (BCM2837)           |
| Architecture | AArch64 (ARM Cortex-A53)                  |
| UART        | PL011 @ `0x3F201000`, 115 200 baud         |

## Run on host (simulation)

```sh
dart pub get
dart run bin/main.dart
```

## Cross-compile for bare metal

```sh
# From the kernel_dart root:
kernel_dart build --target arm64 --platform raspberry_pi
# Flash to SD card:
kernel_dart flash --device /dev/sdX --image build/kernel.bin
```

## Emulate with QEMU

```sh
kernel_dart emulate --platform raspberry_pi --image build/kernel.bin
```
