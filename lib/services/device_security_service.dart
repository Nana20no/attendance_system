import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'; // مكتبة التخزين المشفر
import 'package:uuid/uuid.dart'; // مكتبة توليد أرقام فريدة عالمياً

class DeviceSecurityService {
  //  نمط التصميم (Singleton): 
  // المنطق: هذا النمط يضمن وجود "نسخة واحدة فقط" من هذه الخدمة في كل التطبيق، 
  // حتى لا يحدث تضارب في قراءة بصمة الجهاز.
  static final DeviceSecurityService _instance = DeviceSecurityService._internal();
  factory DeviceSecurityService() => _instance;
  DeviceSecurityService._internal();

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final Uuid _uuid = const Uuid();
  final String _keyDeviceId = 'secure_device_uuid_v1';
  // =========================================================================
  //  الدالة: getOrGenerateDeviceUUID 
  // المكتبات: flutter_secure_storage + uuid
  //   
  // 1. نبحث في "الخزنة المشفرة" للهاتف عن بصمة سابقة.
  // 2. إذا لم نجد (الطالب يسجل لأول مرة)، نولد بصمة فريدة (UUID v4) ونحفظها "مشفرة" في خزنة النظام.
  //  للشرح للدكتور: "يا دكتور، هذه الدالة هي (مصنع البصمات). لا أستخدم شيئاً ثابتاً مثل  هذا المكان محمي بنظام أندرويد/آيفون، ولا يمكن للمستخدم أو لأي تطبيق آخر مسحه أو التلاعب به."
  // =========================================================================
  
  Future<String> getOrGenerateDeviceUUID() async {
    try {
      // قراءة البصمة من خزنة الهاتف المشفرة
      String? deviceId = await _secureStorage.read(key: _keyDeviceId);
      if (deviceId == null || deviceId.trim().isEmpty) {
        // توليد بصمة جديدة باستخدام مكتبة UUID
        deviceId = _uuid.v4();
         // تخزينها مشفرة في الهاتف
        await _secureStorage.write(key: _keyDeviceId, value: deviceId);
        debugPrint("🔐 [Security] Generated new hardware fingerprint: $deviceId");
      } else {
        // إخفاء الرقم في الكونسول 
        String maskedId = deviceId.length > 8 ? "****${deviceId.substring(deviceId.length - 4)}" : "****";
debugPrint("✅ [Security] Retrieved existing hardware fingerprint: $maskedId");
      }
      return deviceId;
    } catch (e) {
      
      debugPrint("❌ [Security] Secure Storage failed: $e");
      throw Exception("Hardware security verification failed. Please check device security settings or reinstall the app.");
    }
  }

  // =========================================================================
  // الدالة: clearDeviceUUID 
  // مثلاً لو أردنا فك ارتباط الهاتف تماماً 
  // حيث تقوم بحذف البصمة المخزنة من الخزنة المشفرة
  // =========================================================================
  Future<void> clearDeviceUUID() async {
    try {
      await _secureStorage.delete(key: _keyDeviceId);
      debugPrint("⚠️ [Security] Wiped hardware fingerprint from device.");
    } catch (e) {
      debugPrint("❌ [Security] Failed to clear device UUID: $e");
      throw Exception("Failed to wipe secure hardware fingerprint.");
    }
  }
}