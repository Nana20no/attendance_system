import 'dart:convert';

class ParsedBleData {
  final String courseCode;
  final String studentId;
  final String deviceHash;

  ParsedBleData({required this.courseCode, required this.studentId, required this.deviceHash});
}

class BlePayloadParser {
  /// Takes raw bytes from BLE advertisement and the current course name.
  /// Returns ParsedBleData if valid and matches the course, otherwise null.
static ParsedBleData? decodeAndVerify(List<int> bytes, String currentCourseName) {
    try {
      String payload = utf8.decode(bytes);
      
      if (!payload.contains(':')) return null;
      
      List<String> parts = payload.split(':');
      if (parts.length < 4) return null; // تعديل: الآن نتوقع 4 أجزاء بدلاً من 3

      String broadcastedCourseCode = parts[0].trim().toLowerCase();
      String studentId = parts[1].replaceAll(RegExp(r'[^0-9]'), ''); 
      String broadcastedDeviceHash = parts[2].trim().toLowerCase();
      String timestampStr = parts[3].trim();

      if (broadcastedCourseCode != currentCourseName.trim().toLowerCase()) return null;
      if (studentId.isEmpty || broadcastedDeviceHash.isEmpty) return null;

      // حماية ضد إعادة البث (Replay Attack) - نرفض أي إشارة أقدم من 60 ثانية
      int? broadcastTimeMs = int.tryParse(timestampStr);
      if (broadcastTimeMs == null) return null;
      
      DateTime broadcastTime = DateTime.fromMillisecondsSinceEpoch(broadcastTimeMs);
      if (DateTime.now().difference(broadcastTime).inSeconds.abs() >120) {
        return null; // رفض الإشارة لأنها قديمة جداً (محاولة غش)
      }

      return ParsedBleData(
        courseCode: broadcastedCourseCode,
        studentId: studentId,
        deviceHash: broadcastedDeviceHash,
      );
    } catch (e) {
      return null; 
    }
  }
}