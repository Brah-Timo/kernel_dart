# Device Driver Guide

`kernel_dart` ships with production-quality drivers for the most common embedded
peripherals. All drivers extend `DeviceDriver` and integrate with `DeviceRegistry`.

---

## Driver Lifecycle

```dart
// Register and initialise
final uart = UARTDriver(baseAddress: 0x3F201000, baudRate: 115200);
DeviceRegistry.instance.register(uart);
await uart.init();

// Use
uart.println('Hello!');

// Clean up
await uart.cleanup();
```

Or use `DeviceRegistry.initAll()` to initialise all registered drivers at once.

---

## UART Driver (PL011)

Supports polling and interrupt-driven TX/RX on the ARM PL011 UART.

### Configuration

```dart
final uart = UARTDriver(
  baseAddress: 0x3F201000,    // Pi 3 UART0
  config: UARTConfig(
    baudRate:          115200,
    wordLength:        UARTWordLength.bits8,
    parity:            UARTParity.none,
    stopBits:          UARTStopBits.one,
    enableFifo:        true,
    enableInterrupts:  false,
    peripheralClockHz: 48000000, // 48 MHz Pi clock
  ),
);
```

Convenience constructors:
- `UARTConfig.standard()` — 115200 8N1 (default)
- `UARTConfig.highSpeed()` — 921600 8N1

### Transmit

```dart
uart.putByte(0x41);                     // single byte
uart.putChar(65);                       // single character
uart.print('Hello World\n');            // string (LF → CRLF by default)
uart.println('Hello');                  // appends \r\n
uart.writeBytes(Uint8List.fromList([1,2,3]));
uart.printf('Value: %d, hex: %x\n', [42, 0xFF]);
```

### Receive

```dart
final byte = uart.getByte();           // blocks until data
final b    = uart.tryGetByte();        // null if empty
final b2   = uart.getByteTimeout(100); // -1 if no data in 100 ms
final buf  = uart.readBytes(16);       // up to 16 bytes
final line = uart.readLine(echo: true);// read until CR/LF
```

### Base addresses

| Board | UART0 base |
|-------|-----------|
| Raspberry Pi 3 | `0x3F201000` |
| Raspberry Pi 4 | `0xFE201000` |
| Generic ARM QEMU | `0x09000000` |
| STM32F4 USART1 | `0x40011000` |

---

## GPIO Driver (BCM2835)

Compatible with Raspberry Pi 1/2/3/4 (BCM2835/2836/2837/2711).

### Pin modes

```dart
gpio.setDirection(17, GPIODirection.output);
gpio.setDirection(18, GPIODirection.input);
gpio.setFunction(4,   GPIOFunction.alt0);    // I2C, SPI alternate functions
```

### Digital I/O

```dart
gpio.writeLevel(17, GPIOLevel.high);   // set HIGH
gpio.writeLevel(17, GPIOLevel.low);    // set LOW
gpio.toggle(17);                        // toggle

final level = gpio.readLevel(18);       // GPIOLevel.high / .low
```

### Pull resistors

```dart
gpio.setPull(18, GPIOPull.pullUp);
gpio.setPull(18, GPIOPull.pullDown);
gpio.setPull(18, GPIOPull.none);
```

### Edge interrupts

```dart
gpio.enableEdgeDetect(18, GPIOEdge.rising);
gpio.onEdge(18, (event) {
  print('Pin ${event.pin}: ${event.level}');
});
```

### LED helpers

```dart
// Blink pin 47 (Pi activity LED) 3 times
await gpio.blinkLED(47, times: 3,
  onDuration:  Duration(milliseconds: 200),
  offDuration: Duration(milliseconds: 200),
);
```

### Atomic bank writes

```dart
// Set pins 0..3 HIGH and pins 4..7 LOW in one register write
gpio.writeBank0(0x0F, 0xF0);
```

---

## I²C Driver (BCM2835 BSC)

### Initialise

```dart
final i2c = I2CDriver(
  baseAddress: 0x3F804000,  // BCM2835 I2C1
  config: I2CConfig(
    speedHz:           400000,    // 400 kHz Fast mode
    peripheralClockHz: 150000000, // 150 MHz core clock / 2
    timeoutMs:         100,
  ),
);
await i2c.init();
```

I²C speeds: `I2CSpeed.standard` (100 kHz), `I2CSpeed.fast` (400 kHz),
`I2CSpeed.fastPlus` (1 MHz).

### Register access

```dart
// Write single byte to register
i2c.writeByte(0x76, 0xF5, 0xA0);    // addr, reg, value

// Read single byte from register
final id = i2c.readByte(0x76, 0xD0); // BMP280 chip ID

// Read 16-bit little-endian signed value
final raw = i2c.readInt16LE(0x76, 0xFA);

// Burst read
final bytes = i2c.readBytes(0x76, 0xF7, 8); // 8 bytes from reg 0xF7
```

### Bus scan

```dart
final devices = i2c.scanBus();  // returns List<int> of responding addresses
for (final addr in devices) {
  print('Found: 0x${addr.toRadixString(16)}');
}
```

---

## SPI Driver (BCM2835 SPI0)

### Initialise

```dart
final spi = SPIDriver(
  baseAddress: 0x3F204000, // BCM2835 SPI0
  config: SPIConfig(
    clockHz:           8000000,    // 8 MHz
    mode:              SPIMode.mode0,
    chipSelect:        SPIChipSelect.cs0,
    bitOrder:          SPIBitOrder.msbFirst,
    peripheralClockHz: 250000000,
  ),
);
await spi.init();
```

SPI modes:
- `SPIMode.mode0` — CPOL=0, CPHA=0 (most common)
- `SPIMode.mode1` — CPOL=0, CPHA=1
- `SPIMode.mode2` — CPOL=1, CPHA=0
- `SPIMode.mode3` — CPOL=1, CPHA=1

### Transfers

```dart
// Full-duplex transfer
final rx = await spi.transfer(Uint8List.fromList([0x9F, 0x00, 0x00]));

// TX only
await spi.write(Uint8List.fromList([0x02, 0x00, 0x00, 0xAB]));

// Single byte
final echo = await spi.transferByte(0x55);

// RX only (send dummy 0xFF)
final data = await spi.read(4);
```

### Sensor register access

```dart
// Write register 0x01 = 0xAA
await spi.writeRegister(0x01, 0xAA);

// Read register 0x01
final val = await spi.readRegisterSpi(0x01);

// Burst read 6 registers from 0x28
final accel = await spi.readRegisters(0x28, 6);
```

---

## Timer Driver (ARM SP804 + BCM2835)

### Initialise

```dart
final timer = TimerDriver(
  baseAddress: 0x3F003000,  // BCM2835 system timer
  clockHz:     1000000,     // 1 MHz
);
await timer.init();
```

### Delays

```dart
timer.delayMs(500);          // busy-wait 500 ms
timer.delayUs(100);          // busy-wait 100 µs
```

### Hardware timer

```dart
// One-shot interrupt after 500 ms
timer.oneShot(Duration(milliseconds: 500));

timer.stop(); // stop timer 1
```

### Software timers

```dart
// Periodic callback every 1 second
final t = timer.scheduleTimer(
  'heartbeat',
  Duration(seconds: 1),
  () => uart.println('tick'),
  repeating: true,
);

// Cancel
timer.cancelTimer(t);
```

### Statistics

```dart
final stats = timer.getStats();
print('Ticks: ${stats.ticks}');
print('Elapsed: ${stats.elapsedMs} ms');
```

---

## Adding a Custom Driver

```dart
final class MyPeripheral extends DeviceDriver {
  final int _base;
  static final _log = Logger('MyPeripheral');

  MyPeripheral({required int baseAddress}) : _base = baseAddress;

  @override
  DeviceInfo get info => DeviceInfo(
    name:        'my_periph',
    description: 'My custom peripheral',
    type:        DeviceType.unknown,
    baseAddress: _base,
    irqNumber:   42,
  );

  @override
  Future<void> init() async {
    // Write control register
    MMIO.write32(_base + 0x00, 0x01); // enable
    status = DeviceStatus.ready;
    _log.info('MyPeripheral init at 0x${_base.toRadixString(16)}');
  }

  @override
  Future<void> cleanup() async {
    MMIO.write32(_base + 0x00, 0x00); // disable
    status = DeviceStatus.removed;
  }

  @override
  void handleIrq(int irqNumber) {
    // Handle interrupt
    final status = MMIO.read32(_base + 0x04); // status register
    MMIO.write32(_base + 0x08, status);        // clear interrupt
  }
}

// Register and use
DeviceRegistry.instance.register(MyPeripheral(baseAddress: 0x10000000));
await DeviceRegistry.instance.initAll();
```
