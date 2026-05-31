# blink_led

> **kernel_dart example** — blink the activity LED on a Raspberry Pi 3.

Drives GPIO pin 47 (the green activity LED on Pi 3B) HIGH/LOW in a tight loop,
printing each transition over UART at 115 200 baud.  
After 5 blink cycles the kernel halts.

## Target

| Field       | Value                                      |
|-------------|--------------------------------------------|
| Board       | Raspberry Pi 3 Model B (BCM2837)           |
| Architecture | AArch64 (ARM Cortex-A53)                  |
| LED GPIO    | Pin 47 (BCM47 = green activity LED)        |
| UART        | PL011 @ `0x3F201000`, 115 200 baud         |

## Run on host (simulation)

```sh
dart pub get
dart run bin/main.dart
```

## Cross-compile & flash

```sh
kernel_dart build --target arm64 --platform raspberry_pi
kernel_dart flash  --device /dev/sdX --image build/kernel.bin
```

## Emulate with QEMU

```sh
kernel_dart emulate --platform raspberry_pi --image build/kernel.bin
```

> **Note**: QEMU's `raspi3b` machine does not model the activity LED GPIO;
> the blink logic still runs and the UART output is visible.
