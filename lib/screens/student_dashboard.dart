import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import '../constants/app_constants.dart';
import '../services/device_security_service.dart';
import '../services/file_parser_service.dart';
import '../mixins/alert_mixin.dart';
import 'login_screen.dart';
import '../services/ble_permission_service.dart';

class StudentDashboard extends StatefulWidget {
  const StudentDashboard({super.key});

  @override
  State<StudentDashboard> createState() => _StudentDashboardState();
  
}

class _StudentDashboardState extends State<StudentDashboard> with AlertMixin , WidgetsBindingObserver {
  final FlutterBlePeripheral _blePeripheral = FlutterBlePeripheral();
  final DeviceSecurityService _securityService = DeviceSecurityService();
  final TextEditingController _courseCodeController = TextEditingController(); // لإدخال رمز المادة
  bool _isBroadcasting = false;
  String? _selectedCourse; // المتغير الجديد للقائمة المنسدلة
  int _timeLeft = AppConstants.broadcastDurationSeconds; 
  Timer? _timer;
  StreamSubscription? _requestSubscription; 
  StreamSubscription<DocumentSnapshot>? _attendanceSubscription;
  String _studentName = "Downloading mapping cache...";
  String _studentId = "Unmapped"; 
  String _secureDeviceId = "";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStudentSecureData();
  }

  Future<void> _loadStudentSecureData() async {
    User? user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        DocumentSnapshot doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        String deviceId = await _securityService.getOrGenerateDeviceUUID();
        if (!mounted) return;
        
        final data = doc.data() as Map<String, dynamic>?;
        setState(() {
          _studentName = data?['name'] ?? "Unknown Authorized Student";
          _studentId = FileParserService.sanitizeId(data?['student_id']);
          _secureDeviceId = deviceId.substring(0, 8); 
        });
      } catch (e) {
        debugPrint("Failed retrieving student mapped structures: $e");
      }
    }
  }

  void _listenForDoctorRequests() {
    _requestSubscription?.cancel();
    _requestSubscription = FirebaseFirestore.instance
        .collection('attendance_requests')
        .where('student_id', isEqualTo: _studentId)
        .where('status', isEqualTo: 'requested')
        .snapshots()
        .listen((snapshot) {
          if (snapshot.docs.isNotEmpty && mounted) {
            _showAttendanceDialog(snapshot.docs.first);
          }
        });
  }

  void _showAttendanceDialog(QueryDocumentSnapshot request) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text("Remote Presence Trigger Request"),
        content: Text("Confirm active classroom participation for module:\n\n${request['course_name']}"),
        actions: [
          TextButton(
            onPressed: () {
              FirebaseFirestore.instance.collection('attendance_requests').doc(request.id).update({'status': 'rejected'});
              Navigator.pop(context);
            }, 
            child: const Text("Ignore", style: TextStyle(color: Colors.redAccent))
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
            onPressed: () {
              FirebaseFirestore.instance.collection('attendance_requests').doc(request.id).update({'status': 'confirmed'});
              _stopBroadcasting(); 
              Navigator.pop(context);
            }, 
            child: const Text("Authorize Verification")
          ),
        ],
      ),
    );
  }

void _listenForAttendanceConfirmation() {
  _attendanceSubscription?.cancel(); // إلغاء أي مستمع قديم إذا كان موجوداً

  User? user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  _attendanceSubscription = FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .snapshots()
      .listen((snapshot) async {
    if (snapshot.exists && snapshot.data() != null) {
      final data = snapshot.data() as Map<String, dynamic>;
      
      // عندما يقوم المعلم بتغيير الحالة إلى 'present'
      if (data['current_status'] == 'present') {
        String courseName = data['confirmed_course'] ?? 'the course';
        // 1. إظهار إشعار محلي (باستخدام الـ SnackBar الحالي لديك)
        if (mounted){
        showAppSnackBar(context, "✅ Attendance Confirmed for $courseName! You may close the app.", isError: false);
        }
        // 2. إيقاف بث الـ BLE تلقائياً
        await _stopBroadcasting();

        // 3. مسح الحالة من Firestore لكي تكون جاهزة للمحاضرة القادمة
        await snapshot.reference.update({'current_status': FieldValue.delete(),
          'confirmed_course': FieldValue.delete()});
      }
    }
  });
}
  Future<void> _toggleBroadcast() async {
    if (_isBroadcasting) {
      await _stopBroadcasting();
    } else {
      await _startBroadcasting();
    }
  }

  Future<void> _startBroadcasting() async {
    if (_studentId == "Unmapped") return;

    String courseCode = _courseCodeController.text.trim().toLowerCase();
    if (courseCode.isEmpty) return;

    bool hasPermissions = await BlePermissionService.requestBlePermissions();
    if (!mounted || !hasPermissions) return;

    // 💡 التحديث الجديد (حل المشكلة): تنظيف أي بيانات حضور قديمة عالقة في السيرفر قبل البث
    User? user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
          'current_status': FieldValue.delete(),
          'confirmed_course': FieldValue.delete()
        });
      } catch (_) {} // نتجاهل الخطأ لو كانت هذه أول مرة ولم يجد بيانات ليمسحها
    }

    // هنا نقوم بدمج البيانات وتشفيرها للإرسال
    int currentTimestamp = DateTime.now().millisecondsSinceEpoch;
    List<int> bytes = utf8.encode("$courseCode:${_studentId.trim()}:${_secureDeviceId.trim()}:$currentTimestamp");

    AdvertiseData advertiseData = AdvertiseData(
      serviceUuid: AppConstants.universityServiceUuid,
      serviceDataUuid: AppConstants.universityServiceUuid, 
      serviceData: Uint8List.fromList(bytes), 
      includeDeviceName: false,
    );

    try {
      await _blePeripheral.start(advertiseData: advertiseData);
      _listenForDoctorRequests(); 
      _listenForAttendanceConfirmation();
      if (mounted) {
        setState(() { 
          _isBroadcasting = true; 
          _timeLeft = AppConstants.broadcastDurationSeconds; 
        });
      }
 
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_timeLeft > 0) {
          if (mounted) setState(() => _timeLeft--);
        } else {
          _stopBroadcasting();
          if (mounted) _showTimeoutDialog(); 
        }
      });
    } catch (e) {
      if (mounted) showAppSnackBar(context, "Hardware mapping failed.");
    }
  }
 
  Future<void> _stopBroadcasting() async {
    try {
      await _blePeripheral.stop();
    } catch (_) {}
    _requestSubscription?.cancel(); 
    _timer?.cancel();
    _attendanceSubscription?.cancel();
    if (mounted) {
      setState(() { 
        _isBroadcasting = false; 
        _timeLeft = AppConstants.broadcastDurationSeconds; 
      });
    }
  }
 //333
// 💡 الدالة الجديدة: نافذة التنبيه عند انتهاء الوقت دون تسجيل
  void _showTimeoutDialog() {
    showDialog(
      context: context,
      barrierDismissible: false, // تمنع إغلاق النافذة بالضغط خارجها
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.timer_off_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 8),
            Text("Session Expired", style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          "Broadcast time has ended (120s).\n\nIf you haven't received a green confirmation message, please check with your instructor to ensure you are marked present.\n\nWould you like to broadcast your signal again?",
          style: TextStyle(fontSize: 15, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), 
            child: const Text("Close", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
            ),
            onPressed: () {
              Navigator.pop(ctx); // إغلاق النافذة
              _startBroadcasting(); // 🔄 إعادة تشغيل البث
            },
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text("Retry Broadcast"),
          ),
        ],
      ),
    );
  }
 //333
  Future<void> _logout() async {
    await _stopBroadcasting();
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }
 
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _requestSubscription?.cancel();
    _attendanceSubscription?.cancel();
    _blePeripheral.stop();
    super.dispose();
  }
 
   @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // If the student minimizes the app (paused), locks their screen (inactive), or kills the app (detached)
    if (state == AppLifecycleState.paused || 
        state == AppLifecycleState.inactive || 
        state == AppLifecycleState.detached) {
      
      if (_isBroadcasting) {
        debugPrint("🛑 App is no longer in the foreground! Force killing BLE broadcast.");
        _stopBroadcasting(); // Immediately stop the hardware broadcast
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("Authorized Device Hub", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(tooltip: "Wipe & Terminate Session", icon: const Icon(Icons.logout, color: Colors.redAccent), onPressed: _logout)
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.indigo.shade100)
                  ),
                  child: Column(
                    children: [
                      Text(_studentName, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.indigo)),
                      const SizedBox(height: 8),
                      Text("Registered ID: ${_studentId == 'Unmapped' ? '...' : _studentId}", style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text("Hardware Token Prefix: ${_secureDeviceId.isEmpty ? '...' : _secureDeviceId}", style: const TextStyle(color: Colors.black54, fontSize: 13)),
                    ],
                  ),
                ),
                
                // --- بداية حقل القائمة المنسدلة للمادة ---
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedCourse,
                    decoration: InputDecoration(
                      labelText: "Select Course",
                      prefixIcon: const Icon(Icons.class_rounded, color: Colors.indigo),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    items: AppConstants.departmentCourses.map((String course) {
                      return DropdownMenuItem<String>(
                        value: course,
                        child: Text(course.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                      );
                    }).toList(),
                    onChanged: _isBroadcasting ? null : (value) {
                      setState(() {
                        _selectedCourse = value;
                        _courseCodeController.text = value ?? ''; // لتحديث المتغير القديم
                      });
                    },
                  ),
                ),
                const SizedBox(height: 32),
                // --- نهاية حقل القائمة المنسدلة للمادة ---
               
                const SizedBox(height: 48),
                GestureDetector(
                  onTap: _toggleBroadcast,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (_isBroadcasting) ...[
                        Container(
                          width: 240, 
                          height: 240,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.green.withValues(alpha: 0.1)),
                        ),
                        Container(
                          width: 210, 
                          height: 210,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.green.withValues(alpha: 0.2)),
                        ),
                      ],
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: 180, 
                        height: 180,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle, 
                          color: _isBroadcasting ? Colors.green.shade600 : Colors.indigo,
                          boxShadow: [
                            BoxShadow(
                              color: (_isBroadcasting ? Colors.green : Colors.indigo).withValues(alpha: 0.4), 
                              blurRadius: 16, 
                              offset: const Offset(0, 8)
                            )
                          ]
                        ),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(_isBroadcasting ? Icons.wifi_tethering_rounded : Icons.touch_app_rounded, size: 50, color: Colors.white),
                              const SizedBox(height: 8),
                              Text(
                                _isBroadcasting ? "Transmitting" : "Verify Token", 
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)
                              ),
                              if (_isBroadcasting) ...[
                                const SizedBox(height: 4),
                                Text("${_timeLeft}s", style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold))
                                                        
                              ]
                                  
//GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 48),
                Text(
                  _isBroadcasting 
                    ? "Keep physical device positioned within proximity limits."
                    : "Tap to initiate low-latency attendance verification beacon.",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}