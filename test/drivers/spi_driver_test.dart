import 'package:kernel_dart/src/drivers/spi_driver.dart';
import 'package:kernel_dart/src/kernel/device_drivers.dart';
import 'package:test/test.dart';

void main() {
  group('SPIConfig', () {
    test('default config has expected values', () {
      const cfg = SPIConfig();
      expect(cfg.clockHz,           equals(1000000));
      expect(cfg.mode,              equals(SPIMode.mode0));
      expect(cfg.chipSelect,        equals(SPIChipSelect.cs0));
      expect(cfg.bitOrder,          equals(SPIBitOrder.msbFirst));
      expect(cfg.peripheralClockHz, equals(250000000));
    });

    test('custom config preserves fields', () {
      const cfg = SPIConfig(
        clockHz:           8000000,
        mode:              SPIMode.mode3,
        chipSelect:        SPIChipSelect.cs1,
        bitOrder:          SPIBitOrder.lsbFirst,
        peripheralClockHz: 125000000,
      );
      expect(cfg.clockHz,           equals(8000000));
      expect(cfg.mode,              equals(SPIMode.mode3));
      expect(cfg.chipSelect,        equals(SPIChipSelect.cs1));
      expect(cfg.bitOrder,          equals(SPIBitOrder.lsbFirst));
      expect(cfg.peripheralClockHz, equals(125000000));
    });
  });

  group('SPIDriver construction', () {
    test('creates with base address', () {
      final spi = SPIDriver(baseAddress: 0x3F204000);
      expect(spi.info.baseAddress, equals(0x3F204000));
    });

    test('device type is spi', () {
      final spi = SPIDriver(baseAddress: 0x3F204000);
      expect(spi.info.type, equals(DeviceType.spi));
    });

    test('device name is spi0', () {
      final spi = SPIDriver(baseAddress: 0x3F204000);
      expect(spi.info.name, equals('spi0'));
    });

    test('initial status is uninitialised', () {
      final spi = SPIDriver(baseAddress: 0x3F204000);
      expect(spi.status, equals(DeviceStatus.uninitialised));
    });
  });

  group('SPIMode enum', () {
    test('has 4 modes', () {
      expect(SPIMode.values.length, equals(4));
    });

    test('modes have correct names', () {
      expect(SPIMode.mode0.name, equals('mode0'));
      expect(SPIMode.mode3.name, equals('mode3'));
    });
  });

  group('SPIChipSelect enum', () {
    test('has cs0, cs1, cs2', () {
      expect(SPIChipSelect.values, containsAll([
        SPIChipSelect.cs0,
        SPIChipSelect.cs1,
        SPIChipSelect.cs2,
      ]));
    });

    test('indices are 0, 1, 2', () {
      expect(SPIChipSelect.cs0.index, equals(0));
      expect(SPIChipSelect.cs1.index, equals(1));
      expect(SPIChipSelect.cs2.index, equals(2));
    });
  });

  group('SPIBitOrder enum', () {
    test('has msbFirst and lsbFirst', () {
      expect(SPIBitOrder.values, containsAll([
        SPIBitOrder.msbFirst,
        SPIBitOrder.lsbFirst,
      ]));
    });
  });

  group('readRegister (sync override)', () {
    test('returns an int without throwing', () {
      final spi = SPIDriver(baseAddress: 0x3F204000);
      expect(() => spi.readRegister(0), returnsNormally);
      expect(spi.readRegister(0), isA<int>());
    });
  });
}
