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
