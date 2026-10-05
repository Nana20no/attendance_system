class AppConstants {
  // Shared BLE Service UUID for University Attendance System
  static const String universityServiceUuid = 'bf27730d-860a-4e09-889c-2d8b6a9e0fe7';
  
  // App-wide Broadcast & Sync Settings
  static const int broadcastDurationSeconds = 120;
  static const int batchUpdateIntervalSeconds = 10;
  
  // Validation Rules
  static const String universityEmailDomain = '@uot.edu.ly';

// قائمة مواد قسم هندسة الكمبيوتر
  static const List<String> departmentCourses = [
    'EC3SD03', 'EC372', 'EC558', 'EC3DD01', 'EC3CO01', 'EC593','EC2CE01','EC3CE02','EC441','EC3CE03','EC3CE04','EC312','EC313','GH152','EC331','EC520','EC301','EC3SP01','EC433','EC482','EC483','EC446','EC448','EC352','EC451'
  ];}