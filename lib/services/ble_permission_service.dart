import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';

class BlePermissionService {
  /// Requests all necessary BLE and Location permissions based on OS & Version.
  /// Returns [true] if all required permissions are granted.
  static Future<bool> requestBlePermissions() async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        final sdkInt = androidInfo.version.sdkInt;

        if (sdkInt >= 31) {
          // Android 12+ (API 31+) Requires specific Bluetooth permissions
          Map<Permission, PermissionStatus> statuses = await [
            Permission.bluetoothScan,
            Permission.bluetoothConnect,
            Permission.bluetoothAdvertise,
          ].request();

          return statuses[Permission.bluetoothScan]!.isGranted &&
                 statuses[Permission.bluetoothConnect]!.isGranted &&
                 statuses[Permission.bluetoothAdvertise]!.isGranted;
        } else {
          // Android 11 and below (API 30-) Requires Location to scan BLE
          Map<Permission, PermissionStatus> statuses = await [
            Permission.bluetooth,
            Permission.location,
          ].request();

          return statuses[Permission.bluetooth]!.isGranted &&
                 statuses[Permission.location]!.isGranted;
        }
      } else if (Platform.isIOS) {
        // iOS only requires the general Bluetooth permission
        PermissionStatus status = await Permission.bluetooth.request();
        return status.isGranted;
      }
      return false; // For Web/Linux/Windows if not supported
    } catch (e) {
      debugPrint("❌ Permission Request Error: $e");
      return false;
    }
  }
}