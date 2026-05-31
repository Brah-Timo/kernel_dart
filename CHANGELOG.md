# Changelog

All notable changes to `kernel_dart` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-05-31

### Added
- Initial public release of `kernel_dart`.
- **Compiler subsystem** — `DartCompiler`, `CrossCompiler`, `CompilationPipeline`,
  `OptimizationPipeline` with tree-shaking, inlining and LTO support.
- **Bootloader generators** — `ARMBootloader` (AArch64 + ARMv7-A),
  `X86Bootloader` (Multiboot2 + UEFI stub), `UefiLoader` (PE32+ EFI Application).
- **Kernel subsystem** — `MemoryManager` (first-fit/best-fit/worst-fit + GC),
  `TaskScheduler` (priority-based + round-robin + CFS), `InterruptHandler`,
  `DeviceRegistry`, `DriverBus`, `KernelApi`.
- **Device drivers** — `UARTDriver` (PL011), `GPIODriver` (BCM2835),
  `I2CDriver` (BCM2835 BSC), `SPIDriver` (BCM2835 SPI0),
  `TimerDriver` (ARM SP804 + BCM2835 system timer).
- **Platform support** — `RaspberryPiPlatform` (Pi 3/4), `STM32Platform`,
  `ESP32Platform`, `GenericArmPlatform`.
- **Runtime** — `DartRuntime`, `GcHandler`, `ExceptionHandler`, `FfiBridge`,
  `MMIO`, `DmaController`.
- **Utilities** — `CompressionUtils` (gzip/zlib/LZ4/CRC32/Adler-32),
  `ElfParser`, `ImageBuilder`, `HexTools`.
- **Configuration** — `PlatformConfig`, `MemoryLayout`, `DeviceTree`.
- **CLI tool** — `kdart` command with `new`, `build`, `flash`, `emulate`,
  `inspect`, `config`, and `analyze` sub-commands.
- **QEMU emulation** — `QemuRunner` for running bare-metal images under QEMU
  (ARM, AArch64, x86-64).
- Comprehensive `doc/` folder covering architecture, API reference, getting
  started, drivers, kernel, compiler, bootloader, and runtime.
- Full `test/` suite covering all major subsystems.

### Platform Support
- Raspberry Pi 3B / 3B+ / 4B (BCM2835 / BCM2711)
- Generic ARM64 / ARM32 (Cortex-A series)
- x86-64 (BIOS/Multiboot2 and UEFI)
- STM32 (Cortex-M series, bare-metal Newlib)
- ESP32 (Xtensa LX6, FreeRTOS-free bare-metal)

[1.0.0]: https://github.com/your-org/kernel_dart/releases/tag/v1.0.0
