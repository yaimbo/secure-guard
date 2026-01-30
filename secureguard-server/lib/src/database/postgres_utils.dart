import 'dart:convert';
import 'dart:typed_data';

import 'package:postgres/postgres.dart' show UndecodedBytes;

/// Utility functions for handling PostgreSQL types from the postgres v3 driver.
/// Keys are stored as TEXT (base64). CIDR/INET types may come as UndecodedBytes.

/// Convert TEXT column (base64) or legacy BYTEA to base64 string
String bytesToBase64(dynamic value) {
  if (value is String) return value; // TEXT column - already base64
  if (value is Uint8List) return base64Encode(value);
  if (value is UndecodedBytes) {
    return base64Encode(Uint8List.fromList(value.bytes));
  }
  if (value is List<int>) return base64Encode(Uint8List.fromList(value));
  return value.toString();
}

/// Convert TEXT column (base64) or legacy BYTEA to Uint8List
Uint8List? bytesToUint8List(dynamic value) {
  if (value == null) return null;
  if (value is String) return base64Decode(value); // TEXT column - base64 string
  if (value is Uint8List) return value;
  if (value is UndecodedBytes) return Uint8List.fromList(value.bytes);
  if (value is List<int>) return Uint8List.fromList(value);
  return null;
}

/// Convert CIDR/INET column to String
/// PostgreSQL INET binary format:
/// - byte 0: address family (2=IPv4, 3=IPv6)
/// - byte 1: prefix length (CIDR bits)
/// - byte 2: is_cidr flag
/// - byte 3: address length (4 for IPv4, 16 for IPv6)
/// - bytes 4+: the address bytes
String pgToString(dynamic value) {
  if (value is String) return value;

  List<int> bytes;
  if (value is UndecodedBytes) {
    bytes = value.bytes;
  } else if (value is List<int>) {
    bytes = value;
  } else {
    return value.toString();
  }

  // Check if this looks like INET binary format
  if (bytes.length >= 8 && (bytes[0] == 2 || bytes[0] == 3)) {
    final family = bytes[0];
    final prefixLen = bytes[1];
    final addrLen = bytes[3];

    if (family == 2 && addrLen == 4 && bytes.length >= 8) {
      // IPv4
      final ip = '${bytes[4]}.${bytes[5]}.${bytes[6]}.${bytes[7]}';
      // Only append prefix if it's not /32 (single host)
      return prefixLen == 32 ? ip : '$ip/$prefixLen';
    } else if (family == 3 && addrLen == 16 && bytes.length >= 20) {
      // IPv6 - format as hex groups
      final parts = <String>[];
      for (var i = 0; i < 16; i += 2) {
        final high = bytes[4 + i];
        final low = bytes[4 + i + 1];
        parts.add(((high << 8) | low).toRadixString(16));
      }
      final ip = parts.join(':');
      return prefixLen == 128 ? ip : '$ip/$prefixLen';
    }
  }

  // Fallback: try as character codes (for text columns)
  return String.fromCharCodes(bytes);
}

/// Parse INET[] array, optionally stripping CIDR suffix
List<String> parseInetArray(dynamic value, {bool stripCidr = false}) {
  if (value == null) return [];
  if (value is! List) return [];

  return value.map((e) {
    final str = pgToString(e);
    if (stripCidr) {
      final slashIndex = str.indexOf('/');
      return slashIndex > 0 ? str.substring(0, slashIndex) : str;
    }
    return str;
  }).toList();
}
