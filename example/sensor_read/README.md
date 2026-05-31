# sensor_read

> **kernel_dart example** — read a BME280 temperature / pressure sensor over
> I²C on a Raspberry Pi 3.

Demonstrates the kernel_dart I²C driver:
- Scans the bus for connected devices.
- Verifies the BME280 chip ID (`0x60`).
- Reads 6 raw data bytes per sample using a burst read.
- Converts raw values to °C / hPa and prints over UART.
- Takes 10 samples at 1-second intervals, then halts.

## Hardware wiring

| BME280 Pin | Raspberry Pi 3 Pin | GPIO   |
|------------|--------------------|--------|
| VCC        | Pin 1 (3.3 V)      | —      |
| GND        | Pin 6 (GND)        | —      |
| SDA        | Pin 3              | GPIO 2 |
| SCL        | Pin 5              | GPIO 3 |

I²C address: **0x76** (SDO → GND).

## Target

| Field       | Value                                      |
|-------------|--------------------------------------------|
| Board       | Raspberry Pi 3 Model B (BCM2837)           |
| Architecture | AArch64 (ARM Cortex-A53)                  |
| I²C base    | `0x3F804000` (BSC1)                        |
| UART        | PL011 @ `0x3F201000`, 115 200 baud         |

## Run on host (simulation)

```sh
dart pub get
dart run bin/main.dart
```

> The I²C calls are simulated (no real hardware needed for host runs).

## Cross-compile & flash

```sh
kernel_dart build --target arm64 --platform raspberry_pi
kernel_dart flash  --device /dev/sdX --image build/kernel.bin
```
