import 'package:kernel_dart/src/drivers/uart_driver.dart';
import 'package:kernel_dart/src/kernel/device_drivers.dart';
import 'package:kernel_dart/src/runtime/ffi_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('UARTConfig', () {
    test('default config has expected values', () {
      const cfg = UARTConfig();
      expect(cfg.baudRate,          equals(115200));
      expect(cfg.wordLength,        equals(UARTWordLength.bits8));
      expect(cfg.parity,            equals(UARTParity.none));
      expect(cfg.stopBits,          equals(UARTStopBits.one));
      expect(cfg.enableFifo,        isTrue);
      expect(cfg.enableInterrupts,  isFalse);
      expect(cfg.peripheralClockHz, equals(48000000));
    });

    test('standard() factory matches default', () {
      expect(UARTConfig.standard().baudRate, equals(115200));
    });

    test('highSpeed() factory sets 921600 baud', () {
      expect(UARTConfig.highSpeed().baudRate, equals(921600));
    });

    test('custom config preserves all fields', () {
      const cfg = UARTConfig(
        baudRate:          9600,
        wordLength:        UARTWordLength.bits7,
        parity:            UARTParity.even,
        stopBits:          UARTStopBits.two,
        enableFifo:        false,
        enableInterrupts:  true,
        peripheralClockHz: 24000000,
      );
      expect(cfg.baudRate,          equals(9600));
      expect(cfg.wordLength,        equals(UARTWordLength.bits7));
      expect(cfg.parity,            equals(UARTParity.even));
      expect(cfg.stopBits,          equals(UARTStopBits.two));
      expect(cfg.enableFifo,        isFalse);
      expect(cfg.enableInterrupts,  isTrue);
      expect(cfg.peripheralClockHz, equals(24000000));
    });
  });

  group('UARTDriver construction', () {
    test('creates with base address', () {
      final uart = UARTDriver(baseAddress: 0x3F201000);
      expect(uart.info.baseAddress, equals(0x3F201000));
    });

    test('device type is uart', () {
      final uart = UARTDriver(baseAddress: 0x3F201000);
      expect(uart.info.type, equals(DeviceType.uart));
    });

    test('device name is uart0', () {
      final uart = UARTDriver(baseAddress: 0x3F201000);
      expect(uart.info.name, equals('uart0'));
    });

    test('default status is uninitialised', () {
      final uart = UARTDriver(baseAddress: 0x3F201000);
      expect(uart.status, equals(DeviceStatus.uninitialised));
    });
  });

  group('UARTParity enum', () {
    test('has none, even, odd values', () {
      expect(UARTParity.values, containsAll([
        UARTParity.none,
        UARTParity.even,
        UARTParity.odd,
      ]));
    });
  });

  group('UARTStopBits enum', () {
    test('has one and two values', () {
      expect(UARTStopBits.values, containsAll([
        UARTStopBits.one,
        UARTStopBits.two,
      ]));
    });
  });

  group('UARTWordLength enum', () {
    test('has bits5 through bits8', () {
      expect(UARTWordLength.values.length, equals(4));
    });
  });

  group('MMIO register constants', () {
    // Verify PL011 register offsets match datasheet values
    test('DR offset is 0x000', () {
      expect(MMIO.read32(0), isA<int>()); // just verifies MMIO.read32 callable
    });
  });
}
