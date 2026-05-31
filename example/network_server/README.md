# network_server

> **kernel_dart example** — cooperative multitasking with hardware interrupts
> on a Raspberry Pi 3.

Demonstrates the kernel_dart **scheduler** and **interrupt handler** by running
three concurrent tasks driven by a 1 kHz hardware timer:

| Task              | Period  | Action                                      |
|-------------------|---------|---------------------------------------------|
| `heartbeat`       | 500 ms  | Toggle activity LED (GPIO 47)               |
| `uart_echo`       | IRQ     | Echo every received UART character          |
| `status_reporter` | 5 s     | Print uptime and active-task count to UART  |

> A full TCP/IP stack is beyond the scope of this example.  
> See [`doc/runtime.md`](../../doc/runtime.md) for the networking roadmap.

## Target

| Field         | Value                                      |
|---------------|--------------------------------------------|
| Board         | Raspberry Pi 3 Model B (BCM2837)           |
| Architecture  | AArch64 (ARM Cortex-A53)                  |
| Timer         | SP804 @ `0x3F003000`, 1 kHz tick           |
| UART          | PL011 @ `0x3F201000`, 115 200 baud         |
| LED GPIO      | Pin 47 (BCM47 = green activity LED)        |

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
kernel_dart emulate --platform raspberry_pi --image build/kernel.bin --debug
# In another terminal, connect GDB:
gdb-multiarch build/kernel.elf
(gdb) target remote :1234
(gdb) continue
```
