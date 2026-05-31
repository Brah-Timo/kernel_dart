# Compiler

`kernel_dart` compiles Dart source files to bare-metal native binaries using a
multi-stage AOT pipeline powered by the Dart SDK toolchain.

---

## Table of Contents

1. [Overview](#overview)
2. [DartCompiler](#dartcompiler)
3. [CrossCompiler](#crosscompiler)
4. [OptimizationPipeline](#optimizationpipeline)
5. [CompilationPipeline](#compilationpipeline)
6. [Enumerations and Value Types](#enumerations-and-value-types)
7. [Full Example](#full-example)

---

## Overview

```
Dart source (.dart)
      |
      v  dart compile kernel
Kernel IR (.dill)
      |
      v  dart compile exe / gen-snapshot
ELF binary (.elf)
      |
      v  OptimizationPipeline (strip + align)
Optimised ELF
      |
      v  objcopy -O binary
Raw binary / bootable image (.bin)
```

The entire pipeline is driven from Dart — no Makefile or shell script required.

---

## DartCompiler

`DartCompiler` wraps the Dart SDK command-line tools (`dart compile kernel` and
`dart compile exe`) to produce architecture-specific AOT binaries.

### Constructor

```dart
DartCompiler({
  required String dartSdkPath,
  required TargetArchitecture architecture,
  CompilerOptions options = const CompilerOptions(),
})
```

| Parameter      | Type                 | Description                         |
|----------------|----------------------|-------------------------------------|
| `dartSdkPath`  | `String`             | Path to the Dart SDK root directory |
| `architecture` | `TargetArchitecture` | Target CPU architecture             |
| `options`      | `CompilerOptions`    | Optional compilation tunables       |

### Key Methods

#### `compileToKernel`

```dart
Future<KernelDill> compileToKernel(String sourcePath, String outputPath)
```

Compile a Dart entry-point to Kernel IR (`.dill`).

#### `compileToNative`

```dart
Future<NativeBinary> compileToNative(KernelDill kernel, String outputPath)
```

AOT-compile a `.dill` to a native ELF binary.

#### `stripBinary`

```dart
Future<void> stripBinary(String elfPath)
```

Strip debug symbols using the cross-toolchain `strip`.

### CompilerOptions

```dart
final class CompilerOptions {
  final bool enableAsserts;         // default false
  final bool soundNullSafety;       // default true
  final OptimizationLevel optLevel; // -O0 / -O1 / -O2 / -O3
  final List<String> extraFlags;
}
```

### Example

```dart
final compiler = DartCompiler(
  dartSdkPath:  '/usr/lib/dart',
  architecture: TargetArchitecture.arm64,
  options: const CompilerOptions(optLevel: OptimizationLevel.o2),
);

final dill   = await compiler.compileToKernel('bin/main.dart', 'build/kernel.dill');
final native = await compiler.compileToNative(dill, 'build/kernel.elf');
print('ELF: ${native.path} (${native.sizeBytes} bytes)');
```

---

## CrossCompiler

`CrossCompiler` adds native GNU cross-toolchain support, enabling re-linking
with a bare-metal linker script.

### Constructor

```dart
CrossCompiler({
  required String dartSdkPath,
  required TargetArchitecture targetArch,
  CompilerOptions options = const CompilerOptions(),
})
```

The appropriate `CrossToolchain` is auto-selected via
`CrossToolchain.forArch(targetArch)`.

### Supported Toolchains

| Architecture | Prefix                     |
|--------------|----------------------------|
| `arm64`      | `aarch64-linux-gnu-`       |
| `arm`        | `arm-linux-gnueabihf-`     |
| `x86_64`     | native (`gcc`, `ld`, …)    |
| `riscv64`    | `riscv64-linux-gnu-`       |

### Main Entry Point

```dart
Future<NativeBinary> compile({
  required String sourcePath,
  required String outputPath,
  bool singleBinary = true,
  String? linkerScript,
})
```

Steps:

1. Verifies the cross-toolchain is on `PATH`
2. Compiles Dart to Kernel IR
3. AOT-compiles to ELF
4. Optionally re-links with the cross-linker + linker script
5. Strips debug symbols

---

## OptimizationPipeline

Applies a sequence of post-compilation optimisation passes.

### Available Passes

| Pass class              | Description                                  |
|-------------------------|----------------------------------------------|
| `StripSectionsPass`     | Remove debug sections with `objcopy`         |
| `UpxPackPass`           | Compress the binary with UPX packer          |
| `CacheAlignPass`        | Align hot sections to cache-line boundaries  |
| `DeadCodeEliminationPass` | Remove unreferenced sections (LTO GC)      |

### Usage

```dart
final pipeline = OptimizationPipeline(
  passes: [StripSectionsPass(), CacheAlignPass(cacheLineSize: 64)],
);
await pipeline.run('build/kernel.elf');
```

### BinaryOptimizer Shortcut

```dart
await BinaryOptimizer.optimise(
  'build/kernel.elf',
  level: OptimizationLevel.o2,
);
```

---

## CompilationPipeline

Top-level orchestrator that chains all steps:

```dart
final pipeline = CompilationPipeline(
  dartSdkPath:  '/usr/lib/dart',
  architecture: TargetArchitecture.arm64,
  platform:     PlatformConfig.raspberryPi3,
  compress:     true,
);

final result = await pipeline.run(
  sourcePath: 'bin/main.dart',
  outputDir:  'build/',
);

print('Image: ${result.imagePath}');
```

---

## Enumerations and Value Types

### TargetArchitecture

```dart
enum TargetArchitecture { arm64, arm, x86_64, riscv64 }
```

### OptimizationLevel

```dart
enum OptimizationLevel { o0, o1, o2, o3 }
```

### KernelDill

```dart
final class KernelDill {
  final String path;
  final int    sizeBytes;
}
```

### NativeBinary

```dart
final class NativeBinary {
  final String            path;
  final TargetArchitecture arch;
  final int               sizeBytes;
}
```

---

## Full Example

```dart
import 'dart:io';
import 'package:kernel_dart/kernel_dart.dart';

Future<void> main() async {
  final sdk = Platform.environment['DART_SDK'] ?? '/usr/lib/dart';

  final compiler = DartCompiler(
    dartSdkPath:  sdk,
    architecture: TargetArchitecture.arm64,
    options: const CompilerOptions(
      soundNullSafety: true,
      optLevel:        OptimizationLevel.o2,
    ),
  );

  final dill = await compiler.compileToKernel('bin/main.dart', 'build/kernel.dill');
  final elf  = await compiler.compileToNative(dill, 'build/kernel.elf');

  await BinaryOptimizer.optimise('build/kernel.elf', level: OptimizationLevel.o2);

  final imagePath = await ImageBuilder.create(
    elf,
    'build/kernel.bin',
    compress:    true,
    platform:    PlatformConfig.raspberryPi3,
    writeHeader: true,
  );
  print('Image written: $imagePath');
}
```

---

## CLI Equivalent

```bash
kdart build --arch arm64 --platform rpi3 --output build/kernel.bin --compress
```
