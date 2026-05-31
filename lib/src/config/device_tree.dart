/// Device tree (FDT) parser and generator for bare-metal hardware description.
///
/// A Device Tree Blob (DTB) describes the hardware topology to the kernel.
/// This module provides:
///   • A lightweight FDT parser (reads binary DTB from firmware)
///   • A DTS (Device Tree Source) generator for known platforms
///   • High-level node / property access API
library;

import 'dart:typed_data';
import 'package:logging/logging.dart';

import 'platform_config.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Device tree constants
// ─────────────────────────────────────────────────────────────────────────────

abstract final class _FdtConst {
  static const int magic       = 0xD00DFEED;
  static const int tokenBeginNode = 0x00000001;
  static const int tokenEndNode   = 0x00000002;
  static const int tokenProp      = 0x00000003;
  static const int tokenNop       = 0x00000004;
  static const int tokenEnd       = 0x00000009;
}

// ─────────────────────────────────────────────────────────────────────────────
// DTNode — in-memory device tree node
// ─────────────────────────────────────────────────────────────────────────────

/// A node in the device tree.
final class DTNode {
  final String name;
  final Map<String, DTProperty> properties;
  final List<DTNode> children;

  DTNode({
    required this.name,
    Map<String, DTProperty>? properties,
    List<DTNode>? children,
  })  : properties = properties ?? {},
        children   = children   ?? [];

  /// Look up a child node by name.
  DTNode? child(String name) {
    for (final c in children) {
      if (c.name == name || c.name.startsWith('$name@')) return c;
    }
    return null;
  }

  /// Get a string property value.
  String? getString(String key) => properties[key]?.asString;

  /// Get a 32-bit integer property value.
  int? getInt(String key) => properties[key]?.asInt;

  /// Get a list of 32-bit integers.
  List<int>? getIntList(String key) => properties[key]?.asIntList;

  @override
  String toString() => 'DTNode($name, ${children.length} children, ${properties.length} props)';
}

/// A device tree property (name → value).
final class DTProperty {
  final String name;
  final Uint8List rawValue;

  DTProperty({required this.name, required this.rawValue});

  DTProperty.string(String name, String value)
      : name     = name,
        rawValue = Uint8List.fromList([...value.codeUnits, 0]);

  DTProperty.int32(String name, int value)
      : name     = name,
        rawValue = Uint8List.fromList([
              (value >> 24) & 0xFF,
              (value >> 16) & 0xFF,
              (value >>  8) & 0xFF,
               value        & 0xFF,
            ]);

  DTProperty.intList(String name, List<int> values)
      : name     = name,
        rawValue = Uint8List.fromList(values.expand((v) => [
              (v >> 24) & 0xFF, (v >> 16) & 0xFF,
              (v >>  8) & 0xFF,  v        & 0xFF,
            ]).toList());

  String? get asString {
    if (rawValue.isEmpty) return null;
    final bytes = rawValue.last == 0 ? rawValue.sublist(0, rawValue.length - 1) : rawValue;
    return String.fromCharCodes(bytes);
  }

  int? get asInt {
    if (rawValue.length < 4) return null;
    return (rawValue[0] << 24) | (rawValue[1] << 16) | (rawValue[2] << 8) | rawValue[3];
  }

  List<int>? get asIntList {
    if (rawValue.length % 4 != 0) return null;
    final result = <int>[];
    for (var i = 0; i < rawValue.length; i += 4) {
      result.add((rawValue[i] << 24) | (rawValue[i+1] << 16) |
                 (rawValue[i+2] << 8) | rawValue[i+3]);
    }
    return result;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DeviceTree
// ─────────────────────────────────────────────────────────────────────────────

/// Parsed device tree.
final class DeviceTree {
  final DTNode root;
  final int bootCpuid;
  final String? version;

  const DeviceTree({
    required this.root,
    this.bootCpuid = 0,
    this.version,
  });

  /// Find a node by path (e.g. `/soc/uart@3f201000`).
  DTNode? nodeAt(String path) {
    if (path == '/') return root;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    DTNode? cur = root;
    for (final part in parts) {
      cur = cur?.child(part);
      if (cur == null) return null;
    }
    return cur;
  }

  /// Find all nodes with a given `compatible` string.
  List<DTNode> findCompatible(String compatible) {
    final result = <DTNode>[];
    _findCompatibleRecursive(root, compatible, result);
    return result;
  }

  void _findCompatibleRecursive(DTNode node, String compat, List<DTNode> out) {
    final c = node.getString('compatible');
    if (c != null && c.contains(compat)) out.add(node);
    for (final child in node.children) {
      _findCompatibleRecursive(child, compat, out);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DeviceTreeParser — reads a binary FDT blob
// ─────────────────────────────────────────────────────────────────────────────

/// Parses a Flattened Device Tree (FDT) binary blob.
final class DeviceTreeParser {
  static final _log = Logger('DeviceTreeParser');

  /// Parse [blob] and return a [DeviceTree].
  ///
  /// Returns null if [blob] does not start with the FDT magic number.
  DeviceTree? parse(Uint8List blob) {
    if (blob.length < 8) return null;

    final magic = _readU32(blob, 0);
    if (magic != _FdtConst.magic) {
      _log.warning('Invalid FDT magic: 0x${magic.toRadixString(16)}');
      return null;
    }

    final totalSize     = _readU32(blob, 4);
    final structOffset  = _readU32(blob, 8);
    final stringsOffset = _readU32(blob, 12);
    final bootCpuid     = _readU32(blob, 28);

    _log.fine('FDT: size=$totalSize, structs=@$structOffset, strings=@$stringsOffset');

    final root  = DTNode(name: '/');
    final stack = <DTNode>[root];

    var pos = structOffset;

    while (pos < totalSize) {
      final token = _readU32(blob, pos);
      pos += 4;

      switch (token) {
        case _FdtConst.tokenBeginNode:
          final name = _readCString(blob, pos);
          pos += _alignUp(name.length + 1);
          final node = DTNode(name: name.isEmpty ? '/' : name);
          stack.last.children.add(node);
          stack.add(node);

        case _FdtConst.tokenEndNode:
          if (stack.length > 1) stack.removeLast();

        case _FdtConst.tokenProp:
          final propLen    = _readU32(blob, pos);       pos += 4;
          final nameOffset = _readU32(blob, pos);       pos += 4;
          final propName   = _readCString(blob, stringsOffset + nameOffset);
          final propValue  = blob.sublist(pos, pos + propLen);
          pos += _alignUp(propLen);

          stack.last.properties[propName] = DTProperty(
            name:     propName,
            rawValue: propValue,
          );

        case _FdtConst.tokenEnd:
          break;

        case _FdtConst.tokenNop:
          break; // no-op
      }

      if (token == _FdtConst.tokenEnd) break;
    }

    return DeviceTree(root: root, bootCpuid: bootCpuid);
  }

  static int _readU32(Uint8List b, int offset) =>
      (b[offset] << 24) | (b[offset+1] << 16) | (b[offset+2] << 8) | b[offset+3];

  static String _readCString(Uint8List b, int offset) {
    final end = b.indexOf(0, offset);
    return String.fromCharCodes(b.sublist(offset, end < 0 ? b.length : end));
  }

  static int _alignUp(int n) => (n + 3) & ~3;
}

// ─────────────────────────────────────────────────────────────────────────────
// DeviceTreeGenerator — produces DTS source for known platforms
// ─────────────────────────────────────────────────────────────────────────────

/// Generates Device Tree Source (DTS) text for a [PlatformConfig].
final class DeviceTreeGenerator {
  final PlatformConfig platform;

  const DeviceTreeGenerator(this.platform);

  /// Generate a minimal DTS file.
  String generateDts() {
    final p = platform;
    return '''
/dts-v1/;

/ {
    compatible = "${p.name}";
    model = "${p.description}";
    #address-cells = <2>;
    #size-cells = <2>;

    cpus {
        #address-cells = <1>;
        #size-cells    = <0>;

        cpu@0 {
            device_type = "cpu";
            compatible  = "arm,${p.architecture.name}";
            reg         = <0>;
            clock-frequency = <${p.cpuClockHz}>;
        };
    };

    memory@${p.ramBase.toRadixString(16)} {
        device_type = "memory";
        reg = <0x0 0x${p.ramBase.toRadixString(16)} 0x0 0x${p.ramSize.toRadixString(16)}>;
    };

    soc {
        compatible      = "simple-bus";
        #address-cells  = <1>;
        #size-cells     = <1>;
        ranges;

        uart0: uart@${p.uartBase.toRadixString(16)} {
            compatible  = "arm,pl011";
            reg         = <0x${p.uartBase.toRadixString(16)} 0x1000>;
            clock-names = "uartclk";
            clocks      = <&clk_uart>;
            status      = "okay";
        };

        gpio0: gpio@${p.gpioBase.toRadixString(16)} {
            compatible  = "brcm,bcm2835-gpio";
            reg         = <0x${p.gpioBase.toRadixString(16)} 0x1000>;
            gpio-controller;
            #gpio-cells = <2>;
            status      = "okay";
        };

        timer0: timer@${p.timerBase.toRadixString(16)} {
            compatible  = "arm,sp804";
            reg         = <0x${p.timerBase.toRadixString(16)} 0x1000>;
            status      = "okay";
        };

        i2c0: i2c@${p.i2cBase.toRadixString(16)} {
            compatible  = "brcm,bcm2835-i2c";
            reg         = <0x${p.i2cBase.toRadixString(16)} 0x1000>;
            #address-cells = <1>;
            #size-cells    = <0>;
            clock-frequency = <400000>;
            status      = "okay";
        };

        spi0: spi@${p.spiBase.toRadixString(16)} {
            compatible  = "brcm,bcm2835-spi";
            reg         = <0x${p.spiBase.toRadixString(16)} 0x1000>;
            #address-cells = <1>;
            #size-cells    = <0>;
            num-cs      = <3>;
            status      = "okay";
        };
    };

    clk_uart: clock-uart {
        compatible    = "fixed-clock";
        #clock-cells  = <0>;
        clock-frequency = <${p.peripheralClockHz}>;
    };
};
''';
  }
}
