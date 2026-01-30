import 'dart:convert';
import 'dart:typed_data';

import 'package:postgres/postgres.dart' show UndecodedBytes;

/// Utility functions for handling PostgreSQL types from the postgres v3 driver.
/// The driver returns BYTEA, CIDR, INET types as UndecodedBytes objects.

/// Convert BYTEA column to base64 string
String bytesToBase64(dynamic bytes) {
  if (bytes is Uint8List) {
    return base64Encode(bytes);
  } else if (bytes is UndecodedBytes) {
    return base64Encode(Uint8List.fromList(bytes.bytes));
  } else if (bytes is List<int>) {
    return base64Encode(Uint8List.fromList(bytes));
  }
  return bytes.toString();
}

/// Convert BYTEA column to Uint8List
Uint8List? bytesToUint8List(dynamic bytes) {
  if (bytes == null) return null;
  if (bytes is Uint8List) return bytes;
  if (bytes is UndecodedBytes) return Uint8List.fromList(bytes.bytes);
  if (bytes is List<int>) return Uint8List.fromList(bytes);
  return null;
}

/// Convert CIDR/INET column to String
String pgToString(dynamic value) {
  if (value is String) return value;
  if (value is UndecodedBytes) return String.fromCharCodes(value.bytes);
  if (value is List<int>) return String.fromCharCodes(value);
  return value.toString();
}

/// Parse INET[] array, optionally stripping CIDR suffix
List<String> parseInetArray(dynamic value, {bool stripCidr = false}) {
  if (value == null) return [];
  if (value is! List) return [];

  return value.map((e) {
    final str =
        e is UndecodedBytes ? String.fromCharCodes(e.bytes) : e.toString();
    if (stripCidr) {
      final slashIndex = str.indexOf('/');
      return slashIndex > 0 ? str.substring(0, slashIndex) : str;
    }
    return str;
  }).toList();
}
