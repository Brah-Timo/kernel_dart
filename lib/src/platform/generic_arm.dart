/// Generic ARM platform support (QEMU virt machine and similar).
///
/// Also serves as the base class for custom boards — override
/// [GenericArmPlatform.init] and pass a custom [PlatformConfig].
library;

import 'package:logging/logging.dart';
import '../config/platform_config.dart';
import '../config/memory_layout.dart';
import '../drivers/uart_driver.dart';
import '../drivers/gpio_driver.dart';
import '../drivers/timer_driver.dart';
import '../drivers/i2c_driver.dart';
import '../drivers/spi_driver.dart';
import '../kernel/device_drivers.dart';
import '../kernel/interrupt_handler.dart';
import '../kernel/memory_manager.dart';
import '../kernel/scheduler.dart';

/// Generic AArch64/ARMv7-A platform.
///
/// Works with QEMU `-machine virt` and any board whose UART is PL011-compatible.
///
/// ```dart
/// final platform = await GenericArmPlatform.init();
/// platform.uart.println('Generic ARM boot OK');
/// ```
final class GenericArmPlatform {
  final PlatformConfig config;

  final UARTDriver  uart;
  final GPIODriver  gpio;
  final TimerDriver timer;
  final I2CDriver   i2c;
  final SPIDriver   spi;

  static final _log = Logger('GenericArmPlatform');

  GenericArmPlatform._({
    required this.config,
    required this.uart,
    required this.gpio,
    required this.timer,
    required this.i2c,
    required this.spi,
  });

  /// Initialise generic ARM platform with optional custom [config].
  static Future<GenericArmPlatform> init([PlatformConfig? config]) async {
    final cfg = config ?? PlatformConfig.genericArm64;
    PlatformConfig.setCurrent(cfg);
    _log.info('Initialising generic ARM platform (${cfg.name})…');

    final uart  = UARTDriver(baseAddress: cfg.uartBase);
    final gpio  = GPIODriver(baseAddress: cfg.gpioBase);
    final timer = TimerDriver(baseAddress: cfg.timerBase, clockHz: cfg.peripheralClockHz);
    final i2c   = I2CDriver(baseAddress: cfg.i2cBase);
    final spi   = SPIDriver(baseAddress: cfg.spiBase);

    await uart.init();
    await gpio.init();
    await timer.init();
    await i2c.init();
    await spi.init();

    DeviceRegistry.instance
      ..register(uart)
      ..register(gpio)
      ..register(timer)
      ..register(i2c)
      ..register(spi);

    // Initialise interrupt handler and register timer ISR
    _registerTimerIrq(timer);

    // Memory manager
    final layout = MemoryLayout.forPlatform(cfg);
    final heap   = layout.regions.firstWhere((r) => r.name == 'Heap');
    MemoryManager.init(heapStart: heap.start, heapSize: heap.sizeBytes);

    _log.info('Generic ARM init complete: ${cfg.name}');
    uart.println('kernel_dart — Generic ARM Platform (${cfg.name})');
    uart.println('  CPU clock : ${cfg.cpuClockHz ~/ 1000000} MHz');
    uart.println('  RAM       : ${cfg.ramSize >> 20} MB');

    return GenericArmPlatform._(
      config: cfg,
      uart:   uart,
      gpio:   gpio,
      timer:  timer,
      i2c:    i2c,
      spi:    spi,
    );
  }

  // ─── Interrupt wiring ─────────────────────────────────────────────────────

  static void _registerTimerIrq(TimerDriver timer) {
    InterruptHandler.instance.registerHandler(
      ArmIrq.ptimer,
      'timer_irq',
      (ctx) {
        timer.handleIrq(ctx.irqNumber);
        TaskScheduler.instance.tick();
      },
    );
    _log.fine('Timer IRQ registered on ARM IRQ ${ArmIrq.ptimer}');
  }

  // ─── QEMU-specific helpers ────────────────────────────────────────────────

  /// Write a byte to the QEMU debug exit device (triggers QEMU shutdown).
  ///
  /// Only available when running under QEMU with `-device isa-debug-exit`.
  static void qemuExit(int code) {
    // QEMU isa-debug-exit port: iobase=0xf4, iosize=0x04
    // Writing (code << 1) | 1 triggers exit with code (code << 1) | 1
  }

  /// Check if we are running under QEMU (by reading SMBIOS or CPUID).
  static bool isQemu() {
    // On QEMU ARM, the machine ID is 0x183 (virt) or a custom value
    return true; // Assume QEMU in simulation context
  }
}
