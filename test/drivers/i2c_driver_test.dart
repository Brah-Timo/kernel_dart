import 'dart:typed_data';

import 'package:kernel_dart/src/drivers/i2c_driver.dart';
import 'package:kernel_dart/src/kernel/device_drivers.dart';
import 'package:test/test.dart';

void main() {
  group('I2CSpeed constants', () {
    test('standard is 100 kHz', () {
      expect(I2CSpeed.standard, equals(100000));
    });

    test('fast is 400 kHz', () {
      expect(I2CSpeed.fast, equals(400000));
    });

    test('fastPlus is 1 MHz', () {
      expect(I2CSpeed.fastPlus, equals(1000000));
    });

    test('highSpeed is 3.4 MHz', () {
      expect(I2CSpeed.highSpeed, equals(3400000));
    });
  });

  group('I2CConfig', () {
    test('default speedHz is I2CSpeed.fast (400 kHz)', () {
      const cfg = I2CConfig();
      expect(cfg.speedHz, equals(I2CSpeed.fast));
    });

    test('default peripheralClockHz is 150 MHz', () {
      const cfg = I2CConfig();
      expect(cfg.peripheralClockHz, equals(150000000));
    });

    test('default timeoutMs is 100', () {
      const cfg = I2CConfig();
      expect(cfg.timeoutMs, equals(100));
    });

    test('custom config stores all fields', () {
      const cfg = I2CConfig(
        speedHz:           I2CSpeed.standard,
        peripheralClockHz: 120000000,
        timeoutMs:         200,
      );
      expect(cfg.speedHz,            equals(I2CSpeed.standard));
      expect(cfg.peripheralClockHz,  equals(120000000));
      expect(cfg.timeoutMs,          equals(200));
    });
  });

  group('I2CError enum', () {
    test('has none, ackError, timeout, busyTimeout, overrun, arbitrationLost', () {
      expect(I2CError.values, containsAll([
        I2CError.none,
        I2CError.ackError,
        I2CError.timeout,
        I2CError.busyTimeout,
        I2CError.overrun,
        I2CError.arbitrationLost,
      ]));
    });
  });

  group('I2CResult', () {
    test('isOk is true when error is none', () {
      final result = I2CResult(error: I2CError.none, data: Uint8List(0));
      expect(result.isOk, isTrue);
    });

    test('isOk is false when error is ackError', () {
      final result = I2CResult(error: I2CError.ackError, data: Uint8List(0));
      expect(result.isOk, isFalse);
    });

    test('data is accessible', () {
      final data   = Uint8List.fromList([1, 2, 3]);
      final result = I2CResult(error: I2CError.none, data: data);
      expect(result.data, equals(data));
    });

    test('toString contains error name and byte count', () {
      final result = I2CResult(error: I2CError.none, data: Uint8List(0));
      expect(result.toString(), contains('none'));
    });
  });

  group('I2CDriver construction', () {
    test('creates with base address', () {
      final i2c = I2CDriver(baseAddress: 0x3F804000);
      expect(i2c.info.baseAddress, equals(0x3F804000));
    });

    test('device type is i2c', () {
      final i2c = I2CDriver(baseAddress: 0x3F804000);
      expect(i2c.info.type, equals(DeviceType.i2c));
    });

    test('device name starts with i2c', () {
      final i2c = I2CDriver(baseAddress: 0x3F804000);
      expect(i2c.info.name, startsWith('i2c'));
    });

    test('initial status is uninitialised', () {
      final i2c = I2CDriver(baseAddress: 0x3F804000);
      expect(i2c.status, equals(DeviceStatus.uninitialised));
    });

    test('custom config is accepted', () {
      final i2c = I2CDriver(
        baseAddress: 0x3F804000,
        config: const I2CConfig(speedHz: I2CSpeed.fastPlus),
      );
      expect(i2c, isNotNull);
    });
  });

  group('scanBus', () {
    test('returns a list of integers (device addresses)', () {
      final i2c = I2CDriver(baseAddress: 0x3F804000);
      final devices = i2c.scanBus();
      expect(devices, isA<List<int>>());
    });
  });
}
