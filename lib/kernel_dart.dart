/// kernel_dart — Ultra-lightweight bare-metal OS kernel for Dart.
///
/// This library exposes every public API needed to:
///   • Compile Dart sources into AOT kernel binaries
///   • Generate bootloaders for ARM / x86 / UEFI targets
///   • Manage memory, tasks and interrupts at the kernel level
///   • Drive hardware peripherals (UART, GPIO, I²C, SPI, Timer)
///   • Build, compress and flash bootable images
///
/// Example
/// ```dart
/// import 'package:kernel_dart/kernel_dart.dart';
///
/// void main() async {
///   final compiler = DartCompiler(
///     dartSdkPath: '/usr/lib/dart',
///     architecture: TargetArchitecture.arm64,
///   );
///   final kernel = await compiler.compileToKernel('bin/main.dart', 'build/kernel.dill');
///   final binary = await compiler.compileToNative(kernel, 'build/kernel.elf');
///   await ImageBuilder.create(binary, 'build/kernel.bin', compress: true);
/// }
/// ```
library kernel_dart;

// ─── Compiler ────────────────────────────────────────────────────────────────
export 'src/compiler/dart_compiler.dart';
export 'src/compiler/optimization.dart';
export 'src/compiler/cross_compile.dart';

// ─── Bootloader ──────────────────────────────────────────────────────────────
export 'src/bootloader/bootloader_arm.dart';
export 'src/bootloader/bootloader_x86.dart';
export 'src/bootloader/uefi_loader.dart';
export 'src/bootloader/boot_protocol.dart';

// ─── Kernel ──────────────────────────────────────────────────────────────────
export 'src/kernel/memory_manager.dart';
export 'src/kernel/scheduler.dart';
export 'src/kernel/interrupt_handler.dart';
export 'src/kernel/device_drivers.dart';
export 'src/kernel/kernel_api.dart';

// ─── Runtime ─────────────────────────────────────────────────────────────────
export 'src/runtime/dart_runtime.dart';
export 'src/runtime/gc_handler.dart';
export 'src/runtime/exception_handling.dart';
export 'src/runtime/ffi_bridge.dart';

// ─── Device Drivers ──────────────────────────────────────────────────────────
export 'src/drivers/uart_driver.dart';
export 'src/drivers/gpio_driver.dart';
export 'src/drivers/timer_driver.dart';
export 'src/drivers/spi_driver.dart';
export 'src/drivers/i2c_driver.dart';

// ─── Utilities ───────────────────────────────────────────────────────────────
export 'src/utils/image_builder.dart';
export 'src/utils/hex_tools.dart';
export 'src/utils/elf_parser.dart';
export 'src/utils/compression.dart';

// ─── Configuration ───────────────────────────────────────────────────────────
export 'src/config/platform_config.dart';
export 'src/config/memory_layout.dart';
export 'src/config/device_tree.dart';

// ─── Emulator ────────────────────────────────────────────────────────────────
export 'src/emulator/qemu_runner.dart';

// ─── Platform Support ────────────────────────────────────────────────────────
export 'src/platform/raspberry_pi.dart';
export 'src/platform/stm32.dart';
export 'src/platform/esp32.dart';
export 'src/platform/generic_arm.dart';
