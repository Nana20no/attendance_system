import 'dart:typed_data';
import 'package:excel/excel.dart';

/// Top-level parser function optimized for execution inside [compute].
List<Map<String, dynamic>> parseExcelFile(Uint8List bytes) {
  var excel = Excel.decodeBytes(bytes);
  List<Map<String, dynamic>> students = [];

  for (var table in excel.tables.keys) {
    var sheet = excel.tables[table];
    if (sheet == null) continue;

    int idCol = 0;   // Default to Column A
    int nameCol = 1; // Default to Column B

    // 1. Smart Column Detection: Read the headers (Row 0)
    var headerRow = sheet.row(0);
    for (int c = 0; c < headerRow.length; c++) {
      String header = headerRow[c]?.value.toString().toLowerCase() ?? '';
      if (header.contains('id') || header.contains('رقم')) idCol = c;
      if (header.contains('name') || header.contains('اسم')) nameCol = c;
    }

    // 2. Processing begins at row 1
    for (var i = 1; i < sheet.maxRows; i++) {
      var row = sheet.row(i);
      if (row.isEmpty) continue;

      // Safely extract data using the detected columns
      String rawId = row.length > idCol ? (row[idCol]?.value.toString().trim() ?? '') : '';
      String rawName = row.length > nameCol ? (row[nameCol]?.value.toString().trim() ?? 'Unknown Student') : 'Unknown Student';

      // Clean ID strings ending in Excel floating point decimals
      if (rawId.endsWith('.0')) {
        rawId = rawId.substring(0, rawId.length - 2);
      }
      
      // Strip everything except numbers
      rawId = rawId.replaceAll(RegExp(r'[^0-9]'), '');

      if (rawId.isNotEmpty) {
        students.add({
          'id': rawId,
          'name': rawName,
          'status': 'absent',
          'device_uuid': '',
        });
      }
    }
  }
  return students;
}

class FileParserService {
  /// Helper utility to safely format raw ID strings across the app.
  static String sanitizeId(dynamic input) {
    if (input == null) return '';
    String str = input.toString().trim();
    if (str.endsWith('.0')) {
      str = str.substring(0, str.length - 2);
    }
    return str.replaceAll(RegExp(r'[^0-9]'), '');
  }
}