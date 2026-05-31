/// kernel_dart CLI — Full command-line interface.
///
/// Commands:
///   new      – scaffold a new bare-metal project
///   build    – compile + link a bootable image
///   flash    – write image to a physical block device
///   emulate  – run image inside QEMU
///   clean    – remove build artefacts
///   info     – show platform & memory information
///   doctor   – check toolchain dependencies
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:kernel_dart/kernel_dart.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

// ─────────────────────────────────────────────────────────────────────────────
// Logger
// ─────────────────────────────────────────────────────────────────────────────

final _log = Logger('kernel_dart');

void _setupLogging({bool verbose = false}) {
  Logger.root.level = verbose ? Level.ALL : Level.INFO;
  Logger.root.onRecord.listen((record) {
    final prefix = switch (record.level) {
      Level.SEVERE  => '\x1B[31m[ERROR]\x1B[0m',
      Level.WARNING => '\x1B[33m[WARN ]\x1B[0m',
      Level.INFO    => '\x1B[32m[ INF ]\x1B[0m',
      Level.FINE    => '\x1B[36m[FINE ]\x1B[0m',
      _             => '[${record.level.name}]',
    };
    stderr.writeln('$prefix ${record.message}');
    if (record.error != null) stderr.writeln('       ${record.error}');
    if (record.stackTrace != null && verbose) {
      stderr.writeln('       ${record.stackTrace}');
    }
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final runner = CommandRunner<void>(
    'kernel_dart',
    '🦾 Ultra-lightweight bare-metal OS kernel for Dart (~2 MB).\n'
    'Run Dart AOT apps directly on ARM/x86 without an OS.',
  )
    ..addCommand(NewCommand())
    ..addCommand(BuildCommand())
    ..addCommand(FlashCommand())
    ..addCommand(EmulateCommand())
    ..addCommand(CleanCommand())
    ..addCommand(InfoCommand())
    ..addCommand(DoctorCommand());

  runner.argParser
    ..addFlag('verbose', abbr: 'v', help: 'Enable verbose output.', negatable: false)
    ..addFlag('version', help: 'Print version and exit.',            negatable: false);

  try {
    final topLevel = runner.argParser.parse(args);

    _setupLogging(verbose: topLevel['verbose'] as bool);

    if (topLevel['version'] as bool) {
      stdout.writeln('kernel_dart 1.0.0');
      return;
    }

    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(e.usage);
    exit(64);
  } on Exception catch (e, st) {
    stderr.writeln('\x1B[31mFatal error:\x1B[0m $e');
    stderr.writeln(st);
    exit(1);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// new command
// ─────────────────────────────────────────────────────────────────────────────

class NewCommand extends Command<void> {
  @override
  String get name => 'new';

  @override
  String get description => 'Scaffold a new bare-metal kernel_dart project.';

  @override
  String get invocation => 'kernel_dart new <project-name> [options]';

  NewCommand() {
    argParser
      ..addOption(
        'platform',
        abbr: 'p',
        help: 'Target platform.',
        allowed: ['raspberry_pi', 'stm32', 'esp32', 'generic_arm', 'x86_64'],
        defaultsTo: 'raspberry_pi',
      )
      ..addOption(
        'template',
        abbr: 't',
        help: 'Project template.',
        allowed: ['hello_world', 'blink_led', 'sensor', 'network'],
        defaultsTo: 'hello_world',
      );
  }

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('Project name is required.');
    }

    final projectName = rest.first;
    final platform    = argResults!['platform']  as String;
    final template    = argResults!['template']  as String;
    final projectDir  = Directory(p.join(Directory.current.path, projectName));

    _log.info('Creating project "$projectName" (platform=$platform, template=$template)…');

    if (projectDir.existsSync()) {
      usageException('Directory "$projectName" already exists.');
    }

    // Scaffold directories
    for (final dir in ['bin', 'lib', 'test']) {
      Directory(p.join(projectDir.path, dir)).createSync(recursive: true);
    }

    // Write pubspec
    File(p.join(projectDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: $projectName
description: A bare-metal Dart application built with kernel_dart.
version: 0.1.0
environment:
  sdk: ">=3.0.0 <4.0.0"
dependencies:
  kernel_dart: ^1.0.0
''');

    // Write main.dart based on template
    final mainCode = _templateCode(template, platform);
    File(p.join(projectDir.path, 'bin', 'main.dart')).writeAsStringSync(mainCode);

    // Write kernel_dart.yaml config
    File(p.join(projectDir.path, 'kernel_dart.yaml')).writeAsStringSync('''
platform: $platform
target_arch: arm64
optimize: true
compress: true
output: build/kernel.bin
''');

    _log.info(
      '\x1B[32m✓ Project "$projectName" created.\x1B[0m\n'
      '  cd $projectName && kernel_dart build',
    );
  }

  String _templateCode(String template, String platform) => switch (template) {
    'blink_led' => r'''
import 'package:kernel_dart/kernel_dart.dart';

void main() {
  final gpio = GPIODriver(baseAddress: PlatformConfig.current.gpioBase);
  const ledPin = 17;
  gpio.setDirection(ledPin, GPIODirection.output);
  while (true) {
    gpio.writeLevel(ledPin, GPIOLevel.high);
    BusyWait.milliseconds(500);
    gpio.writeLevel(ledPin, GPIOLevel.low);
    BusyWait.milliseconds(500);
  }
}
''',
    'sensor' => r'''
import 'package:kernel_dart/kernel_dart.dart';

void main() {
  final uart = UARTDriver(baseAddress: PlatformConfig.current.uartBase, baudRate: 115200);
  final i2c  = I2CDriver(baseAddress: PlatformConfig.current.i2cBase);
  while (true) {
    final raw = i2c.readWord(0x76, 0xFA);
    uart.print('Temp raw: 0x${raw.toRadixString(16)}\r\n');
    BusyWait.seconds(1);
  }
}
''',
    'network' => r'''
import 'package:kernel_dart/kernel_dart.dart';

void main() {
  final uart = UARTDriver(baseAddress: PlatformConfig.current.uartBase, baudRate: 115200);
  uart.print('Network stack not yet available — coming soon!\r\n');
  while (true) {}
}
''',
    _ => r'''
import 'package:kernel_dart/kernel_dart.dart';

void main() {
  final uart = UARTDriver(baseAddress: PlatformConfig.current.uartBase, baudRate: 115200);
  uart.print('Hello from Dart Bare Metal!\r\n');

  final stats = MemoryManager.instance.getMemoryStats();
  uart.print('Total RAM : ${stats.totalMemory} bytes\r\n');
  uart.print('Used  RAM : ${stats.usedMemory}  bytes\r\n');
  uart.print('Free  RAM : ${stats.freeMemory}  bytes\r\n');

  while (true) {}
}
''',
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// build command
// ─────────────────────────────────────────────────────────────────────────────

class BuildCommand extends Command<void> {
  @override
  String get name => 'build';

  @override
  String get description => 'Compile and link a bootable kernel image.';

  BuildCommand() {
    argParser
      ..addOption(
        'target',
        abbr: 't',
        help: 'Target architecture.',
        allowed: ['arm64', 'arm', 'x86_64'],
        defaultsTo: 'arm64',
      )
      ..addOption(
        'platform',
        abbr: 'p',
        help: 'Target board.',
        allowed: ['raspberry_pi', 'stm32', 'esp32', 'generic_arm', 'x86_64'],
        defaultsTo: 'raspberry_pi',
      )
      ..addOption('output', abbr: 'o', help: 'Output binary path.', defaultsTo: 'build/kernel.bin')
      ..addOption('dart-sdk', help: 'Path to Dart SDK.', defaultsTo: '')
      ..addFlag('optimize',  help: 'Enable AOT optimizations.',     defaultsTo: true)
      ..addFlag('strip',     help: 'Strip debug symbols.',          defaultsTo: false, negatable: false)
      ..addFlag('compress',  help: 'Compress final image (gzip).',  defaultsTo: true);
  }

  @override
  Future<void> run() async {
    final arch      = argResults!['target']   as String;
    final platform  = argResults!['platform'] as String;
    final output    = argResults!['output']   as String;
    final optimize  = argResults!['optimize'] as bool;
    final strip     = argResults!['strip']    as bool;
    final compress  = argResults!['compress'] as bool;
    final dartSdk   = (argResults!['dart-sdk'] as String).isEmpty
        ? _detectDartSdk()
        : argResults!['dart-sdk'] as String;

    _log.info('Building for $arch / $platform …');

    final entryPoint = _findEntryPoint();
    final buildDir   = Directory('build')..createSync(recursive: true);
    final dillPath   = p.join(buildDir.path, 'kernel.dill');
    final elfPath    = p.join(buildDir.path, 'kernel.elf');

    // Step 1 — Dart → Kernel IR
    _log.info('[1/4] Compiling Dart → Kernel IR…');
    final compiler = DartCompiler(
      dartSdkPath: dartSdk,
      architecture: TargetArchitecture.fromString(arch),
    );
    final kernelBinary = await compiler.compileToKernel(
      entryPoint,
      dillPath,
      optimize: optimize,
    );
    _log.info('      kernel.dill size: ${kernelBinary.sizeBytes} bytes');

    // Step 2 — Kernel IR → Native ELF
    _log.info('[2/4] Compiling Kernel IR → Native ELF…');
    final nativeBinary = await compiler.compileToNative(
      kernelBinary,
      elfPath,
      stripDebugInfo: strip,
    );
    _log.info('      kernel.elf  size: ${nativeBinary.sizeBytes} bytes');

    // Step 3 — Build bootable image
    _log.info('[3/4] Building bootable image…');
    final imagePath = await ImageBuilder.create(
      nativeBinary,
      output,
      compress: compress,
      platform: PlatformConfig.fromString(platform),
    );

    // Step 4 — Report
    final imageFile = File(imagePath);
    final sizeKb    = (imageFile.lengthSync() / 1024).toStringAsFixed(1);
    _log.info('[4/4] Done.');
    _log.info('\x1B[32m✓ Image: $imagePath  ($sizeKb KB)\x1B[0m');
  }

  String _findEntryPoint() {
    for (final candidate in ['bin/main.dart', 'bin/kernel_dart.dart']) {
      if (File(candidate).existsSync()) return candidate;
    }
    return throw UsageException(
      'No entry point found. Expected bin/main.dart.',
      usage,
    );
  }

  String _detectDartSdk() {
    final result = Process.runSync('dart', ['--version']);
    // The SDK lives one level above the `dart` binary
    final dartBin = result.stdout.toString().trim();
    if (dartBin.isEmpty) return '/usr/lib/dart';
    return p.dirname(p.dirname(Platform.resolvedExecutable));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// flash command
// ─────────────────────────────────────────────────────────────────────────────

class FlashCommand extends Command<void> {
  @override
  String get name => 'flash';

  @override
  String get description => 'Write a kernel image to a physical block device.';

  FlashCommand() {
    argParser
      ..addOption('device', abbr: 'd', help: 'Block device, e.g. /dev/sdb.', mandatory: true)
      ..addOption('image',  abbr: 'i', help: 'Image file to flash.',         defaultsTo: 'build/kernel.bin')
      ..addOption('offset', abbr: 'o', help: 'Write offset in bytes.',        defaultsTo: '0')
      ..addFlag('yes', abbr: 'y', help: 'Skip confirmation prompt.', negatable: false);
  }

  @override
  Future<void> run() async {
    final device = argResults!['device'] as String;
    final image  = argResults!['image']  as String;
    final offset = int.parse(argResults!['offset'] as String);
    final yes    = argResults!['yes']    as bool;

    if (!File(image).existsSync()) {
      usageException('Image file "$image" not found. Run `kernel_dart build` first.');
    }

    if (!yes) {
      stdout.write('\x1B[33m⚠  WARNING: This will overwrite $device. Continue? [y/N] \x1B[0m');
      final answer = stdin.readLineSync() ?? '';
      if (answer.toLowerCase() != 'y') {
        _log.info('Aborted.');
        return;
      }
    }

    _log.info('Flashing $image → $device (offset=$offset)…');

    // Decompress if gzipped
    final imageBytes = await _readAndDecompress(image);

    // Write to device
    final raf = await File(device).open(mode: FileMode.writeOnly);
    await raf.setPosition(offset);
    await raf.writeFrom(imageBytes);
    await raf.flush();
    await raf.close();

    _log.info('\x1B[32m✓ Flash successful! (${imageBytes.length} bytes written)\x1B[0m');
    _log.info('  Safely eject the device before removing it.');
  }

  Future<List<int>> _readAndDecompress(String path) async {
    final bytes = await File(path).readAsBytes();
    if (path.endsWith('.gz')) {
      return CompressionUtils.decompressGzip(bytes);
    }
    return bytes;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// emulate command
// ─────────────────────────────────────────────────────────────────────────────

class EmulateCommand extends Command<void> {
  @override
  String get name => 'emulate';

  @override
  String get description => 'Run a kernel image inside QEMU.';

  EmulateCommand() {
    argParser
      ..addOption(
        'platform',
        abbr: 'p',
        help: 'Board to emulate.',
        allowed: ['raspberry_pi', 'generic_arm', 'x86_64'],
        defaultsTo: 'raspberry_pi',
      )
      ..addOption('image',  abbr: 'i', help: 'Image file.',          defaultsTo: 'build/kernel.bin')
      ..addOption('memory', abbr: 'm', help: 'RAM in MB.',            defaultsTo: '512')
      ..addFlag('debug', abbr: 'd', help: 'Start GDB server on :1234.', negatable: false);
  }

  @override
  Future<void> run() async {
    final platform = argResults!['platform'] as String;
    final image    = argResults!['image']    as String;
    final memory   = argResults!['memory']   as String;
    final debug    = argResults!['debug']    as bool;

    if (!File(image).existsSync()) {
      usageException('Image "$image" not found. Run `kernel_dart build` first.');
    }

    final qemuArgs = QemuRunner.buildArgs(
      platform: PlatformConfig.fromString(platform),
      imagePath: image,
      memoryMb: int.parse(memory),
      debugMode: debug,
    );

    _log.info('Starting QEMU…');
    _log.info('  qemu-system-arm ${qemuArgs.join(' ')}');
    if (debug) _log.info('  GDB server listening on localhost:1234');

    final process = await Process.start('qemu-system-arm', qemuArgs);
    stdout.addStream(process.stdout);
    stderr.addStream(process.stderr);
    await process.exitCode;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// clean command
// ─────────────────────────────────────────────────────────────────────────────

class CleanCommand extends Command<void> {
  @override
  String get name => 'clean';

  @override
  String get description => 'Remove build artefacts.';

  @override
  Future<void> run() async {
    final buildDir = Directory('build');
    if (buildDir.existsSync()) {
      buildDir.deleteSync(recursive: true);
      _log.info('\x1B[32m✓ Build directory removed.\x1B[0m');
    } else {
      _log.info('Nothing to clean.');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// info command
// ─────────────────────────────────────────────────────────────────────────────

class InfoCommand extends Command<void> {
  @override
  String get name => 'info';

  @override
  String get description => 'Show platform and memory layout information.';

  InfoCommand() {
    argParser.addOption(
      'platform',
      abbr: 'p',
      help: 'Platform to inspect.',
      allowed: ['raspberry_pi', 'stm32', 'esp32', 'generic_arm', 'x86_64'],
      defaultsTo: 'raspberry_pi',
    );
  }

  @override
  Future<void> run() async {
    final platform = PlatformConfig.fromString(argResults!['platform'] as String);
    final layout   = MemoryLayout.forPlatform(platform);

    stdout.writeln('\n\x1B[1mPlatform: ${platform.name}\x1B[0m');
    stdout.writeln('  Architecture : ${platform.architecture.name}');
    stdout.writeln('  UART base    : 0x${platform.uartBase.toRadixString(16).padLeft(8, '0')}');
    stdout.writeln('  GPIO base    : 0x${platform.gpioBase.toRadixString(16).padLeft(8, '0')}');
    stdout.writeln('  Timer base   : 0x${platform.timerBase.toRadixString(16).padLeft(8, '0')}');
    stdout.writeln('  I²C base     : 0x${platform.i2cBase.toRadixString(16).padLeft(8, '0')}');
    stdout.writeln('  SPI base     : 0x${platform.spiBase.toRadixString(16).padLeft(8, '0')}');
    stdout.writeln('\n\x1B[1mMemory Layout\x1B[0m');
    for (final region in layout.regions) {
      final start = '0x${region.start.toRadixString(16).padLeft(8, '0')}';
      final end   = '0x${region.end.toRadixString(16).padLeft(8, '0')}';
      final kb    = (region.sizeBytes / 1024).toStringAsFixed(0).padLeft(6);
      stdout.writeln('  $start – $end  ${kb.padLeft(6)} KB  ${region.name}');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// doctor command
// ─────────────────────────────────────────────────────────────────────────────

class DoctorCommand extends Command<void> {
  @override
  String get name => 'doctor';

  @override
  String get description => 'Check toolchain and system dependencies.';

  @override
  Future<void> run() async {
    stdout.writeln('\n\x1B[1mkernel_dart doctor\x1B[0m\n');

    final checks = <({String tool, String hint})>[
      (tool: 'dart',                       hint: 'Install Dart SDK ≥ 3.0'),
      (tool: 'aarch64-linux-gnu-gcc',      hint: 'sudo apt install gcc-aarch64-linux-gnu'),
      (tool: 'aarch64-linux-gnu-ld',       hint: 'sudo apt install binutils-aarch64-linux-gnu'),
      (tool: 'arm-linux-gnueabihf-gcc',    hint: 'sudo apt install gcc-arm-linux-gnueabihf'),
      (tool: 'qemu-system-arm',            hint: 'sudo apt install qemu-system-arm'),
      (tool: 'objcopy',                    hint: 'sudo apt install binutils'),
      (tool: 'gzip',                       hint: 'sudo apt install gzip'),
      (tool: 'gdb-multiarch',              hint: 'sudo apt install gdb-multiarch'),
    ];

    var allOk = true;
    for (final check in checks) {
      final result = Process.runSync('which', [check.tool]);
      final found  = result.exitCode == 0;
      final icon   = found ? '\x1B[32m✓\x1B[0m' : '\x1B[31m✗\x1B[0m';
      final hint   = found ? '' : '  → ${check.hint}';
      stdout.writeln('  $icon  ${check.tool.padRight(32)} ${found ? 'OK' : 'NOT FOUND'}$hint');
      if (!found) allOk = false;
    }

    stdout.writeln('');
    if (allOk) {
      stdout.writeln('\x1B[32m✓ All checks passed! You are ready to build.\x1B[0m\n');
    } else {
      stdout.writeln('\x1B[33m⚠  Some tools are missing. Install them and run `doctor` again.\x1B[0m\n');
    }
  }
}
