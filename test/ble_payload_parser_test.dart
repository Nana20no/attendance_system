import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
// Replace with your actual project import path
import 'package:attendance_system/utils/ble_payload_parser.dart'; 

void main() {
  group('BlePayloadParser.decodeAndVerify', () {
    const String currentCourse = 'ec555';
    

    test('successfully parses a valid payload for the correct course', () {
      // Arrange
      String rawString = 'ec555:22181324:9ff0f749';
      List<int> bytes = utf8.encode(rawString);

      // Act
      var result = BlePayloadParser.decodeAndVerify(bytes, currentCourse);

      // Assert
      expect(result, isNotNull);
      expect(result!.courseCode, 'ec555');
      expect(result.studentId, '22181324');
      expect(result.deviceHash, '9ff0f749');
    });

    test('rejects payload if course code does not match (Neighboring classroom)', () {
      // Arrange
      String rawString = 'cs101:22181324:9ff0f749'; // Different course
      List<int> bytes = utf8.encode(rawString);

      // Act
      var result = BlePayloadParser.decodeAndVerify(bytes, currentCourse);

      // Assert
      expect(result, isNull);
    });

    test('sanitizes student ID by removing non-numeric characters', () {
      // Arrange (e.g., student ID accidently has spaces or letters)
      String rawString = 'ec555: 2218-1324A :9ff0f749';
      List<int> bytes = utf8.encode(rawString);

      // Act
      var result = BlePayloadParser.decodeAndVerify(bytes, currentCourse);

      // Assert
      expect(result, isNotNull);
      expect(result!.studentId, '22181324'); // Should be perfectly clean
    });

    test('returns null for malformed payloads missing colons', () {
      // Arrange
      String rawString = 'ec555221813249ff0f749';
      List<int> bytes = utf8.encode(rawString);

      // Act
      var result = BlePayloadParser.decodeAndVerify(bytes, currentCourse);

      // Assert
      expect(result, isNull);
    });

    test('returns null for incomplete payloads', () {
      // Arrange (Missing the hash part)
      String rawString = 'ec555:22181324';
      List<int> bytes = utf8.encode(rawString);

      // Act
      var result = BlePayloadParser.decodeAndVerify(bytes, currentCourse);

      // Assert
      expect(result, isNull);
    });

    test('does not crash on invalid UTF-8 byte sequences', () {
      // Arrange (Corrupt bytes that aren't valid UTF-8)
      List<int> corruptBytes = [0xFF, 0xFE, 0xFD];

      // Act
      var result = BlePayloadParser.decodeAndVerify(corruptBytes, currentCourse);

      // Assert
      expect(result, isNull); // Should catch the FormatException and return null gracefully
    });
  });
}