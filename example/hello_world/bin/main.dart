/// Hello World — kernel_dart bare-metal example.
///
/// Prints a greeting and memory statistics over UART, allocates and frees a
/// small heap block to show the memory manager in action, then loops forever.
///
/// Target: Raspberry Pi 3 (AArch64, BCM2837).
///
/// Build & cross-compile for bare metal:
/// ```
/// dart pub get
/// kernel_dart build --target arm64 --platform raspberry_pi
/// ```
library;

import 'package:kernel_dart/kernel_dart.dart';

void main() {
  // ── Initialise UART (PL011 @ 115 200 baud) ───────────────────────────────
  final uart = UARTDriver(
    baseAddress: PlatformConfig.raspberryPi3.uartBase,
    baudRate: 115200,
  );

  uart.println('');
  uart.println('╔══════════════════════════════════════════╗');
  uart.println('║  kernel_dart  —  Hello from Bare Metal!  ║');
  uart.println('╚══════════════════════════════════════════╝');
  uart.println('');

  // ── Platform information ─────────────────────────────────────────────────
  final cfg = PlatformConfig.raspberryPi3;
  uart.println('Platform  : ${cfg.name}');
  uart.println('CPU clock : ${cfg.cpuClockHz ~/ 1000000} MHz');
  uart.println('RAM total : ${cfg.ramSize >> 20} MB');
  uart.println(
    'UART base : 0x${cfg.uartBase.toRadixString(16).padLeft(8, '0')}',
  );
  uart.println(
    'GPIO base : 0x${cfg.gpioBase.toRadixString(16).padLeft(8, '0')}',
  );
  uart.println('');

  // ── Kernel memory manager ────────────────────────────────────────────────
  final mm = MemoryManager.init(
    heapStart: cfg.ramBase + 0x248000,
    heapSize: cfg.ramSize - 0x248000 - 0x100000,
  );

  final stats = mm.getMemoryStats();
  uart.println('Heap start : 0x${(cfg.ramBase + 0x248000).toRadixString(16)}');
  uart.println('Heap size  : ${stats.totalMemory >> 10} KB');
  uart.println('Free       : ${stats.freeMemory >> 10} KB');
  uart.println('');

  // ── Allocate and free a small block to verify the heap works ─────────────
  final blockA = mm.allocate(1024); // 1 KB
  uart.println(
    'Allocated 1 KB @ 0x${blockA.toRadixString(16).padLeft(8, '0')}',
  );

  final blockB = mm.allocate(4096); // 4 KB
  uart.println(
    'Allocated 4 KB @ 0x${blockB.toRadixString(16).padLeft(8, '0')}',
  );

  mm.deallocate(blockA);
  uart.println('Freed 1 KB block.');

  mm.deallocate(blockB);
  uart.println('Freed 4 KB block.');
  uart.println('');

  final statsAfter = mm.getMemoryStats();
  uart.println('Free after dealloc: ${statsAfter.freeMemory >> 10} KB');
  uart.println('');
  uart.println('Boot complete — spinning in idle loop.');

  // ── Idle loop ─────────────────────────────────────────────────────────────
  while (true) {
    // In a real kernel: `asm volatile("wfi")` — Wait For Interrupt.
  }
}
