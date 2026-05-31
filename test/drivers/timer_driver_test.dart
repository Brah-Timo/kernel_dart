import 'package:kernel_dart/src/drivers/timer_driver.dart';
import 'package:kernel_dart/src/kernel/device_drivers.dart';
import 'package:test/test.dart';

void main() {
  group('TimerDriver construction', () {
    test('creates with base address', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      expect(timer.info.baseAddress, equals(0x3F003000));
    });

    test('device type is timer', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      expect(timer.info.type, equals(DeviceType.timer));
    });

    test('device name starts with timer', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      expect(timer.info.name, startsWith('timer'));
    });

    test('initial status is uninitialised', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      expect(timer.status, equals(DeviceStatus.uninitialised));
    });

    test('default clockHz is 1 MHz', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      expect(timer.clockHz, equals(1000000));
    });

    test('custom clockHz is stored', () {
      final timer = TimerDriver(baseAddress: 0x3F003000, clockHz: 10000000);
      expect(timer.clockHz, equals(10000000));
    });
  });

  group('TimerDriver ticks and elapsed time', () {
    test('ticks starts at 0', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      expect(timer.ticks, equals(0));
    });

    test('elapsedMs starts at 0', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      expect(timer.elapsedMs, equals(0));
    });

    test('elapsedUs starts at 0', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      expect(timer.elapsedUs, equals(0));
    });
  });

  group('SoftwareTimer', () {
    test('can be created with required fields', () {
      final sw = SoftwareTimer(
        name:        'blink',
        interval:    const Duration(milliseconds: 500),
        callback:    () {},
        initialTick: 0,
      );
      expect(sw, isNotNull);
      expect(sw.name, equals('blink'));
    });

    test('active is true when created', () {
      final sw = SoftwareTimer(
        name:        'idle',
        interval:    const Duration(seconds: 1),
        callback:    () {},
        initialTick: 0,
      );
      expect(sw.active, isTrue);
    });

    test('id is unique per timer instance', () {
      final sw1 = SoftwareTimer(name: 'a', interval: const Duration(seconds: 1),
          callback: () {}, initialTick: 0);
      final sw2 = SoftwareTimer(name: 'b', interval: const Duration(seconds: 1),
          callback: () {}, initialTick: 0);
      expect(sw1.id, isNot(equals(sw2.id)));
    });

    test('repeating defaults to false', () {
      final sw = SoftwareTimer(
        name:        'once',
        interval:    const Duration(milliseconds: 100),
        callback:    () {},
        initialTick: 0,
      );
      expect(sw.repeating, isFalse);
    });

    test('repeating can be set to true', () {
      final sw = SoftwareTimer(
        name:        'loop',
        interval:    const Duration(milliseconds: 100),
        callback:    () {},
        repeating:   true,
        initialTick: 0,
      );
      expect(sw.repeating, isTrue);
    });
  });

  group('TimerDriver.scheduleTimer', () {
    test('scheduleTimer returns a SoftwareTimer', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      final sw = timer.scheduleTimer(
        'heartbeat',
        const Duration(milliseconds: 500),
        () {},
      );
      expect(sw, isA<SoftwareTimer>());
      expect(sw.name, equals('heartbeat'));
    });

    test('scheduled timer is active', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      final sw = timer.scheduleTimer('t', const Duration(seconds: 1), () {});
      expect(sw.active, isTrue);
    });

    test('cancelTimer deactivates the timer', () {
      final driver = TimerDriver(baseAddress: 0x3F003000);
      final sw = driver.scheduleTimer('cancel_me', const Duration(seconds: 1), () {});
      driver.cancelTimer(sw);
      expect(sw.active, isFalse);
    });
  });

  group('TimerStats', () {
    test('getStats returns TimerStats', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      final stats = timer.getStats();
      expect(stats, isA<TimerStats>());
    });

    test('initial stats have 0 ticks', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      final stats = timer.getStats();
      expect(stats.ticks, equals(0));
    });

    test('stats clockHz matches driver clockHz', () {
      final timer = TimerDriver(baseAddress: 0x3F003000, clockHz: 2000000);
      final stats = timer.getStats();
      expect(stats.clockHz, equals(2000000));
    });

    test('toString contains ticks and clock', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      final stats = timer.getStats();
      expect(stats.toString(), contains('ticks'));
    });
  });

  group('TimerDriver.delayUs', () {
    test('delayUs is callable without throwing (very short delay)', () {
      final timer = TimerDriver(baseAddress: 0x3F003000);
      // With _ticks=0 and readCounter64 reading from MMIO (all zeros), this
      // returns immediately since target = 0 + us and counter starts at 0.
      expect(() => timer.delayUs(0), returnsNormally);
    });
  });
}
