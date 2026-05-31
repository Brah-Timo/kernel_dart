/// Sensor Read — kernel_dart bare-metal example.
///
/// Reads temperature and pressure from a Bosch BME280 sensor
/// connected via I²C (address 0x76) on a Raspberry Pi 3.
/// Prints 10 readings at 1-second intervals over UART, then halts.
///
/// Wiring (Raspberry Pi 3B GPIO header):
///   BME280 VCC  → Pin 1  (3.3 V)
///   BME280 GND  → Pin 6  (GND)
///   BME280 SDA  → Pin 3  (GPIO 2, I²C SDA)
///   BME280 SCL  → Pin 5  (GPIO 3, I²C SCL)
///
/// Build & flash:
/// ```
/// kernel_dart build --target arm64 --platform raspberry_pi
/// kernel_dart flash  --device /dev/sdX
/// ```
library;

import 'package:kernel_dart/kernel_dart.dart';

// ── BME280 register addresses ─────────────────────────────────────────────────

/// BME280 I²C address (SDO pulled LOW → 0x76).
const int kBme280Addr     = 0x76;

/// Chip ID register — always reads 0x60 for BME280.
const int kRegChipId      = 0xD0;

/// Soft reset register — write 0xB6 to reset.
const int kRegReset       = 0xE0;

/// Control measurement register (temp + pressure oversampling + mode).
const int kRegCtrlMeas    = 0xF4;

/// Oversampling ×1 for temperature and pressure, forced mode.
const int kCtrlMeasValue  = 0x27;

/// Pressure MSB register (base of 6-byte burst: press + temp).
const int kRegPressureMsb = 0xF7;

void main() {
  final cfg = PlatformConfig.raspberryPi3;

  // ── UART ────────────────────────────────────────────────────────────────
  final uart = UARTDriver(baseAddress: cfg.uartBase, baudRate: 115200);
  uart.println('[sensor_read] Initialising…');

  // ── I²C ─────────────────────────────────────────────────────────────────
  final i2c = I2CDriver(
    baseAddress: cfg.i2cBase,
    config: const I2CConfig(speedHz: I2CSpeed.fast),
  );

  // ── Scan bus ─────────────────────────────────────────────────────────────
  uart.println('[sensor_read] Scanning I²C bus…');
  final devices = i2c.scanBus();
  if (devices.isEmpty) {
    uart.println('[sensor_read] No I²C devices found. Check wiring.');
  } else {
    for (final addr in devices) {
      uart.println(
        '[sensor_read]   Found device @ '
        '0x${addr.toRadixString(16).padLeft(2, '0')}',
      );
    }
  }

  // ── Verify BME280 chip ID ────────────────────────────────────────────────
  final chipId = i2c.readByte(kBme280Addr, kRegChipId);
  if (chipId != 0x60) {
    uart.println(
      '[sensor_read] BME280 not found '
      '(chip_id=0x${chipId.toRadixString(16)}). Expected 0x60.',
    );
    while (true) {}
  }
  uart.println('[sensor_read] BME280 detected (chip_id=0x60).');

  // ── Configure sensor ─────────────────────────────────────────────────────
  i2c.writeByte(kBme280Addr, kRegReset, 0xB6); // soft reset
  _busyDelay(10);                               // 10 ms reset time
  i2c.writeByte(kBme280Addr, kRegCtrlMeas, kCtrlMeasValue);
  uart.println('[sensor_read] BME280 configured (forced mode, ×1 OSR).');
  uart.println('');

  // ── Read loop ─────────────────────────────────────────────────────────────
  for (var sample = 1; sample <= 10; sample++) {
    // Trigger forced-mode measurement
    i2c.writeByte(kBme280Addr, kRegCtrlMeas, kCtrlMeasValue);
    _busyDelay(10); // wait ~9.3 ms for measurement to complete

    // Burst-read 6 bytes: press_msb, press_lsb, press_xlsb,
    //                     temp_msb,  temp_lsb,  temp_xlsb
    final d = i2c.readBytes(kBme280Addr, kRegPressureMsb, 6);

    if (d.length < 6) {
      uart.println('[sensor_read] Short read — I²C error, aborting.');
      break;
    }

    final rawPress = (d[0] << 12) | (d[1] << 4) | (d[2] >> 4);
    final rawTemp  = (d[3] << 12) | (d[4] << 4) | (d[5] >> 4);

    // Simplified linear conversion (no calibration trimming data applied).
    // Real firmware reads trim coefficients from 0x88–0xA1 and 0xE1–0xF0.
    final tempC    = (rawTemp  / 5243.0) - 40.0;
    final pressPa  = (rawPress / 4096.0) * 100.0 + 87000.0;
    final presshPa = pressPa / 100.0;

    uart.println(
      'Sample ${'$sample'.padLeft(2)}/10 | '
      'Temp: ${tempC.toStringAsFixed(1).padLeft(6)} °C | '
      'Pressure: ${presshPa.toStringAsFixed(1).padLeft(8)} hPa  '
      '[raw T=0x${rawTemp.toRadixString(16).padLeft(5, '0')} '
      'P=0x${rawPress.toRadixString(16).padLeft(5, '0')}]',
    );

    _busyDelay(1000); // 1 s between samples
  }

  uart.println('');
  uart.println('[sensor_read] 10 samples complete. Halting.');
  while (true) {}
}

/// Busy-wait delay. [ms] milliseconds at ~1.2 GHz Cortex-A53.
///
/// In production firmware, replace with `TimerDriver.scheduleTimer`.
void _busyDelay(int ms) {
  // ~120 000 iterations ≈ 1 ms at 1.2 GHz with a 10-cycle NOP loop.
  const iterPerMs = 120000;
  for (var i = 0; i < ms * iterPerMs; i++) {
    CPU.nop();
  }
}
