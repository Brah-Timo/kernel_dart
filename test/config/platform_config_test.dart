import 'package:kernel_dart/src/compiler/dart_compiler.dart';
import 'package:kernel_dart/src/config/platform_config.dart';
import 'package:test/test.dart';

void main() {
  group('PlatformConfig presets', () {
    test('raspberryPi3 architecture is arm64', () {
      expect(PlatformConfig.raspberryPi3.architecture,
          equals(TargetArchitecture.arm64));
    });

    test('raspberryPi3 has correct UART base', () {
      expect(PlatformConfig.raspberryPi3.uartBase, equals(0x3F201000));
    });

    test('raspberryPi3 has correct GPIO base', () {
      expect(PlatformConfig.raspberryPi3.gpioBase, equals(0x3F200000));
    });

    test('raspberryPi3 RAM is 1 GB', () {
      expect(PlatformConfig.raspberryPi3.ramSize, equals(0x40000000));
    });

    test('raspberryPi4 UART base is different from Pi 3', () {
      expect(PlatformConfig.raspberryPi4.uartBase,
          isNot(equals(PlatformConfig.raspberryPi3.uartBase)));
    });

    test('raspberryPi4 architecture is arm64', () {
      expect(PlatformConfig.raspberryPi4.architecture,
          equals(TargetArchitecture.arm64));
    });

    test('stm32f4 architecture is arm', () {
      expect(PlatformConfig.stm32f4.architecture,
          equals(TargetArchitecture.arm));
    });

    test('genericArm64 architecture is arm64', () {
      expect(PlatformConfig.genericArm64.architecture,
          equals(TargetArchitecture.arm64));
    });

    test('name field is non-empty for all presets', () {
      for (final preset in [
        PlatformConfig.raspberryPi3,
        PlatformConfig.raspberryPi4,
        PlatformConfig.stm32f4,
        PlatformConfig.stm32h7,
        PlatformConfig.esp32,
        PlatformConfig.genericArm64,
      ]) {
        expect(preset.name, isNotEmpty);
      }
    });

    test('cpuClockHz is positive for all presets', () {
      for (final preset in [
        PlatformConfig.raspberryPi3,
        PlatformConfig.raspberryPi4,
        PlatformConfig.genericArm64,
      ]) {
        expect(preset.cpuClockHz, greaterThan(0));
      }
    });
  });

  group('PlatformConfig.current / setCurrent', () {
    test('setCurrent updates current', () {
      PlatformConfig.setCurrent(PlatformConfig.raspberryPi3);
      expect(PlatformConfig.current.name,
          equals(PlatformConfig.raspberryPi3.name));
    });

    test('current persists across calls', () {
      PlatformConfig.setCurrent(PlatformConfig.raspberryPi4);
      expect(PlatformConfig.current.uartBase,
          equals(PlatformConfig.raspberryPi4.uartBase));
    });
  });

  group('TargetArchitecture enum', () {
    test('has arm64, arm, x86_64, riscv64', () {
      expect(TargetArchitecture.values, containsAll([
        TargetArchitecture.arm64,
        TargetArchitecture.arm,
        TargetArchitecture.x86_64,
        TargetArchitecture.riscv64,
      ]));
    });
  });

  group('PlatformConfig fields', () {
    test('ramBase is non-negative', () {
      expect(PlatformConfig.raspberryPi3.ramBase, greaterThanOrEqualTo(0));
    });

    test('i2cBase is non-zero', () {
      expect(PlatformConfig.raspberryPi3.i2cBase, isNot(equals(0)));
    });

    test('spiBase is non-zero', () {
      expect(PlatformConfig.raspberryPi3.spiBase, isNot(equals(0)));
    });

    test('timerBase is non-zero', () {
      expect(PlatformConfig.raspberryPi3.timerBase, isNot(equals(0)));
    });

    test('peripheralClockHz is positive', () {
      expect(PlatformConfig.raspberryPi3.peripheralClockHz, greaterThan(0));
    });

    test('description is non-empty', () {
      expect(PlatformConfig.raspberryPi3.description, isNotEmpty);
    });

    test('toJson returns a map with name key', () {
      final json = PlatformConfig.raspberryPi3.toJson();
      expect(json, containsPair('name', 'raspberry_pi_3'));
    });
  });

  group('PlatformConfig.fromString', () {
    test('parses raspberry_pi_3', () {
      expect(PlatformConfig.fromString('raspberry_pi_3').name,
          equals('raspberry_pi_3'));
    });

    test('parses generic_arm64', () {
      expect(PlatformConfig.fromString('generic_arm64').name,
          equals('generic_arm64'));
    });

    test('throws ArgumentError for unknown platform', () {
      expect(() => PlatformConfig.fromString('unknown_board'),
          throwsA(isA<ArgumentError>()));
    });
  });
}
