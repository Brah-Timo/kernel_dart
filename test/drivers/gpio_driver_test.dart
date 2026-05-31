import 'package:kernel_dart/src/drivers/gpio_driver.dart';
import 'package:kernel_dart/src/kernel/device_drivers.dart';
import 'package:test/test.dart';

void main() {
  group('GPIODriver construction', () {
    test('creates with base address', () {
      final gpio = GPIODriver(baseAddress: 0x3F200000);
      expect(gpio.info.baseAddress, equals(0x3F200000));
    });

    test('device type is gpio', () {
      final gpio = GPIODriver(baseAddress: 0x3F200000);
      expect(gpio.info.type, equals(DeviceType.gpio));
    });

    test('device name is gpio0', () {
      final gpio = GPIODriver(baseAddress: 0x3F200000);
      expect(gpio.info.name, equals('gpio0'));
    });

    test('initial status is uninitialised', () {
      final gpio = GPIODriver(baseAddress: 0x3F200000);
      expect(gpio.status, equals(DeviceStatus.uninitialised));
    });
  });

  group('GPIODirection enum', () {
    test('has input and output', () {
      expect(GPIODirection.values, containsAll([
        GPIODirection.input,
        GPIODirection.output,
      ]));
    });
  });

  group('GPIOLevel enum', () {
    test('has low and high', () {
      expect(GPIOLevel.values, containsAll([GPIOLevel.low, GPIOLevel.high]));
    });
  });

  group('GPIOFunction enum', () {
    test('has 8 values (input, output, alt0-alt5)', () {
      expect(GPIOFunction.values.length, equals(8));
    });

    test('contains input and output', () {
      expect(GPIOFunction.values, containsAll([
        GPIOFunction.input,
        GPIOFunction.output,
      ]));
    });
  });

  group('GPIOPull enum', () {
    test('has none, pullUp, pullDown', () {
      expect(GPIOPull.values, containsAll([
        GPIOPull.none,
        GPIOPull.pullUp,
        GPIOPull.pullDown,
      ]));
    });
  });

  group('GPIOEdge enum', () {
    test('has rising, falling, both, none', () {
      expect(GPIOEdge.values, containsAll([
        GPIOEdge.rising,
        GPIOEdge.falling,
        GPIOEdge.both,
        GPIOEdge.none,
      ]));
    });
  });

  group('GpioPinEvent', () {
    test('stores pin, level, and timestamp', () {
      final event = GpioPinEvent(
        pin:       17,
        level:     GPIOLevel.high,
        timestamp: DateTime(2026),
      );
      expect(event.pin,       equals(17));
      expect(event.level,     equals(GPIOLevel.high));
      expect(event.timestamp, equals(DateTime(2026)));
    });
  });

  group('_validatePin (via setDirection)', () {
    test('throws ArgumentError for pin > 53', () {
      final gpio = GPIODriver(baseAddress: 0x3F200000);
      expect(
        () => gpio.setDirection(54, GPIODirection.output),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws ArgumentError for negative pin', () {
      final gpio = GPIODriver(baseAddress: 0x3F200000);
      expect(
        () => gpio.setDirection(-1, GPIODirection.input),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
