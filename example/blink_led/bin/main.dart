/// Blink LED — kernel_dart bare-metal example.
///
/// Blinks GPIO pin 47 (activity LED on Raspberry Pi 3B)
/// five times, then prints a summary over UART and halts.
///
/// Target: Raspberry Pi 3 (AArch64, BCM2837).
///
/// Build & flash:
/// ```
/// kernel_dart build --target arm64 --platform raspberry_pi
/// kernel_dart flash  --device /dev/sdX
/// ```
library;

import 'package:kernel_dart/kernel_dart.dart';

/// Activity LED GPIO pin on Raspberry Pi 3B.
const int kLedPin = 47;

/// Number of blink cycles before halting.
const int kBlinkCount = 5;

/// On-time per blink in milliseconds.
const int kOnMs = 500;

/// Off-time per blink in milliseconds.
const int kOffMs = 500;

void main() {
  final cfg  = PlatformConfig.raspberryPi3;

  // ── UART for debug output ─────────────────────────────────────────────────
  final uart = UARTDriver(baseAddress: cfg.uartBase, baudRate: 115200);
  uart.println('[blink_led] Initialising GPIO…');

  // ── GPIO driver ───────────────────────────────────────────────────────────
  final gpio = GPIODriver(baseAddress: cfg.gpioBase);

  // Configure LED pin as output
  gpio.setDirection(kLedPin, GPIODirection.output);
  uart.println('[blink_led] LED pin $kLedPin → OUTPUT');
  uart.println('[blink_led] Starting $kBlinkCount blink cycles…');

  // ── Blink loop ────────────────────────────────────────────────────────────
  for (var i = 1; i <= kBlinkCount; i++) {
    // LED ON
    gpio.writeLevel(kLedPin, GPIOLevel.high);
    uart.println('[blink_led] Cycle $i/$kBlinkCount — LED ON');
    _busyDelay(kOnMs);

    // LED OFF
    gpio.writeLevel(kLedPin, GPIOLevel.low);
    uart.println('[blink_led] Cycle $i/$kBlinkCount — LED OFF');
    _busyDelay(kOffMs);
  }

  uart.println('[blink_led] Done. LED is OFF. Halting.');

  // ── Halt ──────────────────────────────────────────────────────────────────
  while (true) {}
}

/// Simple busy-wait delay (calibrated for ~1.2 GHz Cortex-A53).
///
/// In a real kernel, replace with `TimerDriver.delayMs(ms)`.
void _busyDelay(int ms) {
  // ~12 000 iterations ≈ 1 ms at 1.2 GHz with a 10-cycle loop body.
  const iterPerMs = 120000;
  for (var i = 0; i < ms * iterPerMs; i++) {
    CPU.nop();
  }
}
