/// Network Server — kernel_dart bare-metal example.
///
/// Demonstrates the kernel scheduler and software timer subsystem by running
/// three periodic tasks on a Raspberry Pi 3:
///
///   • Heartbeat     — blinks the activity LED every 500 ms via a software timer.
///   • UART listener — reads a line of input and echoes it prefixed with `> `.
///   • Status report — prints a system status snapshot every 5 seconds.
///
/// A full bare-metal TCP/IP stack is outside the scope of this example.
/// See `doc/runtime.md` for the networking roadmap.
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

// ── Constants ─────────────────────────────────────────────────────────────────

/// Activity LED GPIO pin (green LED on Raspberry Pi 3B).
const int kLedPin = 47;

void main() {
  final cfg = PlatformConfig.raspberryPi3;

  // ── UART ─────────────────────────────────────────────────────────────────
  final uart = UARTDriver(baseAddress: cfg.uartBase, baudRate: 115200);
  uart.println('');
  uart.println('╔═══════════════════════════════════════════╗');
  uart.println('║   kernel_dart  —  Network Server Example  ║');
  uart.println('╚═══════════════════════════════════════════╝');
  uart.println('');

  // ── GPIO ─────────────────────────────────────────────────────────────────
  final gpio = GPIODriver(baseAddress: cfg.gpioBase);
  gpio.setDirection(kLedPin, GPIODirection.output);

  // ── Timer driver ─────────────────────────────────────────────────────────
  final timer = TimerDriver(
    baseAddress: cfg.timerBase,
    clockHz: cfg.peripheralClockHz,
  );

  // ── Interrupt handler ─────────────────────────────────────────────────────
  final irq = InterruptHandler.instance;
  irq.enableInterrupts();

  // Wire the SP804 timer IRQ (BCM2835 IRQ 36) to drive the software timer.
  irq.registerHandler(
    ArmIrq.timer0,
    'timer_tick',
    (_) => timer.handleIrq(ArmIrq.timer0),
  );

  // ── Software timers ───────────────────────────────────────────────────────

  // Task 1: heartbeat — toggles LED every 500 ms
  timer.scheduleTimer(
    'heartbeat',
    const Duration(milliseconds: 500),
    () => gpio.toggle(kLedPin),
    repeating: true,
  );
  uart.println('[timer] Heartbeat scheduled (500 ms, LED pin $kLedPin).');

  // Task 2: status reporter — prints stats every 5 s
  var statusCount = 0;
  timer.scheduleTimer(
    'status_reporter',
    const Duration(seconds: 5),
    () {
      statusCount++;
      final s = TaskScheduler.instance.stats();
      uart.println(
        '[status] Uptime: ${statusCount * 5} s | '
        'Tasks: ${s.totalTasks} total, ${s.readyTasks} ready | '
        'Context switches: ${s.contextSwitches}',
      );
    },
    repeating: true,
  );
  uart.println('[timer] Status reporter scheduled (5 s).');

  // ── Scheduler tasks ───────────────────────────────────────────────────────
  final scheduler = TaskScheduler.instance;

  // Task 3: UART echo — reads a line and echoes it
  scheduler.addTask(
    'uart_echo',
    () {
      uart.print('Type something and press Enter: ');
      final line = uart.readLine(echo: true);
      uart.println('');
      uart.println('> $line');
    },
    priority: 1,
  );

  uart.println('');
  uart.println('System running. Type a line and press Enter to echo it.');
  uart.println('The LED will blink every 500 ms.');
  uart.println('');

  // ── Idle loop — scheduler drives tasks; timer drives LED + stats ──────────
  while (true) {
    scheduler.tick();
    CPU.nop();
  }
}
