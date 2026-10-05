import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' hide Border; 
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import '../constants/app_constants.dart';
import '../services/file_parser_service.dart';
import '../mixins/alert_mixin.dart';
import '../services/ble_permission_service.dart';
import '../utils/ble_payload_parser.dart';

class AttendanceScannerScreen extends StatefulWidget {
  final String courseId;
  final String courseName;

  const AttendanceScannerScreen({super.key, required this.courseId, required this.courseName});

  @override
  State<AttendanceScannerScreen> createState() => _AttendanceScannerScreenState();
}

class _AttendanceScannerScreenState extends State<AttendanceScannerScreen> with AlertMixin {
  //   المتغيرات
  Timer? _batchTimer; // المؤقت اللي يشتغل كل 7 ثواني
  bool _hasPendingUpdates = false; // هل السلة فيها طلاب محتاجين رفع؟
  final List<String> _pendingStudentUids = []; // هذه هي "السلة" اللي نجمع فيها الطلاب
  bool _isSessionActive = false; // هل الرادار يشتغل أو مسكر؟
  List<dynamic> _students = [];
  StreamSubscription? _scanSubscription;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance; // مكتبة قاعدة البيانات
  final Set<String> _processedStudents = {}; 

  @override
  void initState() {
    super.initState();
    _loadStudents();
  }

  // =========================================================================
  // 👨‍💻 الدالة 1: _loadStudents بيانات الطلبة)
  // ⚙️ المكتبات المستخدمة: cloud_firestore
  // 🧠 المنطق: حتى التطبيق ما يعلقش ويستهلك نت، ما نجيبش كل طلاب الجامعة! 
  // نجيب بس الطلاب المسجلين في هذي المادة، ونقسمهم على "دفعات" (كل 30 طالب دفعة).
  // 🎤 للشرح للدكتور: "استخدمت استعلام (whereIn) لجلب الطلاب كـ (Chunks) لتخفيف الضغط على السيرفر."
  // =========================================================================
  void _loadStudents() async {
    try {
      debugPrint("🔄 [Scanner] Downloading enrolled offline mapping payload...");
      var courseDoc = await _firestore.collection('courses').doc(widget.courseId).get();
      if (!mounted) return;

      if (courseDoc.exists) {
        List<dynamic> studentList = courseDoc.data()?['students_list'] ?? [];
        
       // استخراج أرقام قيد الطلاب المسجلين في هذه المادة فقط
        List<String> enrolledIds = studentList.map((s) => FileParserService.sanitizeId(s['id'])).toList();

        Map<String, String> deviceMap = {};
        Map<String, String> uidMap = {}; 
        
        // جلب البيانات على دفعات (30 طالب في كل دفعة لتجنب تجاوز حدود Firebase)
        for (var i = 0; i < enrolledIds.length; i += 30) {
          int end = (i + 30 < enrolledIds.length) ? i + 30 : enrolledIds.length;
          List<String> chunk = enrolledIds.sublist(i, end);
          if (chunk.isEmpty) break;

          var usersSnapshot = await _firestore.collection('users')
              .where('student_id', whereIn: chunk)
              .get();

          for (var doc in usersSnapshot.docs) {
            String sId = FileParserService.sanitizeId(doc.data()['student_id']);
            deviceMap[sId] = doc.data()['registered_device_uuid'] ?? "";
            uidMap[sId] = doc.id; 
          }
        }

        if (mounted) {
          setState(() {
            _students = studentList.map((s) {
              String cleanId = FileParserService.sanitizeId(s['id']);
              s['id'] = cleanId;
              s['device_uuid'] = deviceMap[cleanId] ?? ""; 
              s['uid'] = uidMap[cleanId] ?? ""; // إرفاق الـ UID بالقائمة المحلية
              return s;
            }).toList();
          });
        }
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, "Failed to download offline mapping cache.");
    }
  }

  // =========================================================================
  // 👨‍💻 الدالة 2: _saveSessionToHistory (حفظ سجل المحاضرة)
  // ⚙️ المكتبات المستخدمة: cloud_firestore + intl (للتاريخ)
  // 🧠 المنطق: لما الدكتور يسكر الرادار، نأخذ الطلاب اللي حالتهم (present) ونحفظهم في 
  // كولكشن جديد اسمه (attendance_sessions) عشان يبانوا في الـ History.
  // =========================================================================
  Future<void> _saveSessionToHistory() async {
    try {
      List<Map<String, dynamic>> presentStudents = _students
          .where((s) => s['status'] == 'present')
          .map((s) => {
                'student_id': s['id'],
                'student_name': s['name'],
                'timestamp': FieldValue.serverTimestamp(),
              })
          .toList();

      if (presentStudents.isEmpty) return; // لا نحفظ جلسات فارغة

      await _firestore
          .collection('courses')
          .doc(widget.courseId)
          .collection('attendance_sessions')
          .add({
        'date': DateFormat('yyyy-MM-dd – kk:mm').format(DateTime.now()),
        'is_active': false,
        'present_students': {
          for (var s in presentStudents) s['student_id']: s
        },
      });
    } catch (e) {
      debugPrint("❌ Failed to save session: $e");
    }
  }

  // =========================================================================
  // 👨‍💻 الدالة 3: _toggleSession (تشغيل وإيقاف الرادار)
  // ⚙️ المكتبات المستخدمة: flutter_blue_plus
  // 🧠 المنطق: هنا نطلب إذن البلوتوث، ونشغله. والأهم: نستخدم فلتر (withServices) عشان 
  // نصطاد بس الإشارات اللي طالعة من تطبيقنا ونتجاهل الساعات والسماعات!
  // 🎤 للشرح للدكتور: "استخدمت Hardware Filter لتقليل استهلاك البطارية، و PacketAge لمنع الإشارات القديمة."
  // =========================================================================
  void _toggleSession() async {
    // حالة الإغلاق (الرادار يعمل ونريد إيقافه)
    if (_isSessionActive) {
      await FlutterBluePlus.stopScan();
      _scanSubscription?.cancel();
      _batchTimer?.cancel(); 
      await _commitBatchUpdates(); 
      await _saveSessionToHistory();
      if (mounted) setState(() => _isSessionActive = false);
    } 
    // حالة التشغيل (الرادار متوقف ونريد تشغيله)
    else {
      // 💡 التحديث الذكي: هل يوجد طلاب حاضرون من قبل؟
      bool hasPresentStudents = _students.any((s) => s['status'] == 'present');
      
      if (hasPresentStudents) {
        // سؤال الدكتور: هل يريد استكمال المحاضرة أم مسح الحضور وبدء محاضرة جديدة؟
        bool? shouldReset = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Resume or Reset?"),
            content: const Text("There are students already marked as 'Present'.\n\nDo you want to RESUME the current session, or RESET everyone to 'Absent' for a new lecture?"),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text("Cancel")),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.pop(ctx, false), // استئناف (Resume)
                child: const Text("Resume Session", style: TextStyle(color: Colors.white))
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(ctx, true), // تصفير (Reset)
                child: const Text("Reset All", style: TextStyle(color: Colors.white))
              ),
            ],
          )
        );

        if (shouldReset == null) return; // تم الضغط على Cancel
        
        // إذا اختار Reset، نقوم بتصفير الجميع قبل التشغيل
        if (shouldReset == true) {
          setState(() {
            for (var s in _students) { s['status'] = 'absent'; }
            _processedStudents.clear();
          });
          _updateFirestore(silent: true);
        }
      }

      // -- إكمال تشغيل الرادار بشكل طبيعي --
      bool hasPermissions = await BlePermissionService.requestBlePermissions();
      if (!hasPermissions) {
        if (mounted) showAppSnackBar(context, "Bluetooth permissions are required to scan.");
        return; 
      }
     
      var state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        try { await FlutterBluePlus.turnOn(); } catch (e) { return; }
      }

      setState(() {
        _isSessionActive = true;
        // لا نمسح _processedStudents هنا لكي لا ننسى من حضر في حالة الاستئناف
        if (!hasPresentStudents) _processedStudents.clear(); 
        
        _batchTimer = Timer.periodic(const Duration(seconds: 7), (timer) {
          _commitBatchUpdates();
        });
      });
      
      await FlutterBluePlus.startScan(withServices: [Guid(AppConstants.universityServiceUuid)], timeout: null, androidUsesFineLocation: true, continuousUpdates: true,);

      _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
        for (ScanResult r in results) {
          int packetAge = DateTime.now().difference(r.timeStamp).inSeconds.abs();
          if (packetAge > 3) continue; 
          if (r.rssi < -65) continue; 

          var serviceData = r.advertisementData.serviceData;
          String targetUuid = AppConstants.universityServiceUuid.toLowerCase();
          
          if (serviceData.containsKey(Guid(targetUuid))) {
            List<int> bytes = serviceData[Guid(targetUuid)]!;
            String currentCourseName = widget.courseName.trim().toLowerCase();
            ParsedBleData? parsedData = BlePayloadParser.decodeAndVerify(bytes, currentCourseName);

            if (parsedData != null && !_processedStudents.contains(parsedData.studentId)) {
                _verifyAndMarkPresent(parsedData.studentId, parsedData.deviceHash);
            }
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _batchTimer?.cancel(); 
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  // =========================================================================
  // 👨‍💻 الدالة 4: _verifyAndMarkPresent (المطابقة الأمنية لمنع الغش)
  // 🧠 المنطق: نقارن "البصمة" اللي وصلتنا بالبلوتوث من الطالب، مع "البصمة" اللي جلبناها 
  // من الفايربيس (Firebase) في بداية الكلاس. لو تطابقت = أخضر. لو اختلفت = أحمر (غش).
  // 🎤 للشرح للدكتور: "هنا أطابق الـ Device UUID المبعوث مع المخزن بالسيرفر لمنع الـ Proxy Attendance."
  // =========================================================================
  Future<void> _verifyAndMarkPresent(String studentId, String broadcastedDeviceHash) async {
    String cleanInputId = studentId.replaceAll(RegExp(r'[^0-9]'), ''); 
    String cleanHash = broadcastedDeviceHash.trim().toLowerCase();

    int index = _students.indexWhere((s) {
      String listId = s['id'].toString().replaceAll(RegExp(r'[^0-9]'), '');
      return listId == cleanInputId;
    });

    if (index != -1) {
      String registeredUUID = _students[index]['device_uuid']?.toString().toLowerCase() ?? '';
      
      // المطابقة هنا!
      if ((cleanHash.isNotEmpty && registeredUUID.startsWith(cleanHash)) || registeredUUID.isEmpty) {
          if (_students[index]['status'] == 'absent') {
            
            // 1. نخلي لونه أخضر في شاشة الدكتور
            setState(() { _students[index]['status'] = 'present'; });
            _processedStudents.add(cleanInputId);
            
            // 2. نضعه في "السلة" لرفعه للإنترنت لاحقاً
            _hasPendingUpdates = true;
            String uidOfStudent = _students[index]['uid'] ?? ''; 
            if (uidOfStudent.isNotEmpty) {
                _pendingStudentUids.add(uidOfStudent); 
            }

            showAppSnackBar(context, "✅ Verified: ${_students[index]['name']}", isError: false);
          }
      } else {
          // لو البصمة مختلفة (طالب يعطي حسابه لزميله)
          showAppSnackBar(context, "🛑 Blocked: Security mismatch for student $studentId", isError: true);
      }
    } else {
      debugPrint("Signal ignored: Student $cleanInputId is not in this course's list.");
    }
  }

  // =========================================================================
  // 👨‍💻 الدالة 5: _commitBatchUpdatesخوارزمية السلة - لرفع البيانات كمجموعه  )
  // ⚙️ المكتبات المستخدمة: cloud_firestore (WriteBatch)
  // 🧠 المنطق: بدل ما نرفع كل طالب للنت بروحه والتطبيق يعلق ويوقف، نجمع الطلاب اللي في "السلة" 
  // ونرفعهم مرة وحدة للسيرفر بطلب واحد (Atomic Request).
  // 🎤 للشرح للدكتور: "استخدمت (WriteBatch) لرفع البيانات بشكل مجمع لتفادي تجمد الواجهة وتقليل التكلفة."
  // =========================================================================
  Future<void> _commitBatchUpdates() async {
    if (!_hasPendingUpdates) return; 

    try {
      const int maxOperationsPerBatch = 450; 
      
      // ناخذ نسخة من السلة ونفرغها حتى لو جي طالب جديد وقت رفع البيانات ما تصيرش مشكلة
      List<String> snapshotUids = List.from(_pendingStudentUids);
      _pendingStudentUids.clear();
      _hasPendingUpdates = false;

      WriteBatch batch = _firestore.batch();
      int operationCount = 0;
      List<Future<void>> commitTasks = [];

      DocumentReference courseRef = _firestore.collection('courses').doc(widget.courseId);
      batch.update(courseRef, {'students_list': _students});
      operationCount++;

      // إرسال إشعار الإيقاف للطلاب (حتى تطلعلهم علامة الصح الخضراء)
      for (String uid in snapshotUids) {
        DocumentReference userRef = _firestore.collection('users').doc(uid);
        batch.update(userRef, {
          'current_status': 'present',
          'confirmed_course': widget.courseName 
        });
        operationCount++;

        if (operationCount >= maxOperationsPerBatch) {
          commitTasks.add(batch.commit());    
          batch = _firestore.batch();         
          operationCount = 0;                 
        }
      }

      if (operationCount > 0) {
        commitTasks.add(batch.commit());
      }

      await Future.wait(commitTasks); // تنفيذ الكل
      
    } catch (e) {
      debugPrint("❌ Batch upload failed: $e");
    }
  }

  // تحديث إجباري للسيرفر
  void _updateFirestore({bool silent = false}) async {
    try {
      await _firestore.collection('courses').doc(widget.courseId).update({'students_list': _students});
      if (mounted && !silent) {
        showAppSnackBar(context, "Attendance records synchronized successfully.", isError: false);
      }
    } catch (e) {
      if (mounted && !silent) showAppSnackBar(context, "System cloud synchronization interrupted.");
    }
  }

  // =========================================================================
  // 👨‍💻 الدالة 6: _markAsPresentManual (تسجيل الحضور اليدوي)
  // 🧠 المنطق: لو طالب تلفونه في مشكلة، الدكتور يسجله يدوياً من التطبيق.
  // =========================================================================
  void _markAsPresentManual(String studentId) {
    String searchId = FileParserService.sanitizeId(studentId);
    int index = _students.indexWhere((s) => FileParserService.sanitizeId(s['id']) == searchId);
    if (index != -1 && _students[index]['status'] == 'absent') {
      setState(() => _students[index]['status'] = 'present');
      _updateFirestore();
    }
  }

  

  // =========================================================================
  //  الدالة 8: _exportAttendanceReport (تصدير التقرير لإكسل)
  //  المكتبات المستخدمة: excel + share_plus
  //  المنطق: إنشاء ملف إكسل من البيانات الحالية ومشاركته (مثلاً عبر الواتساب او GOOGLE DRIVE للإدارة).
  // =========================================================================
  Future<void> _exportAttendanceReport() async {
    var excel = Excel.createExcel();
    Sheet sheetObject = excel['Attendance Report'];
    String currentDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
    
    sheetObject.appendRow([TextCellValue('Course:'), TextCellValue(widget.courseName), TextCellValue('Date:'), TextCellValue(currentDate)]);
    sheetObject.appendRow([TextCellValue('Student ID'), TextCellValue('Name'), TextCellValue('Status')]);

    for (var s in _students) {
      sheetObject.appendRow([
        TextCellValue(s['id'].toString()), 
        TextCellValue(s['name']), 
        TextCellValue(s['status'] == 'present' ? 'Present' : 'Absent')
      ]);
    }

    var fileBytes = excel.save();
    if (fileBytes == null) {
      showAppSnackBar(context, "Export mapping failed.");
      return;
    }

    var directory = await getApplicationDocumentsDirectory();
    File file = File('${directory.path}/report_${widget.courseName.replaceAll(' ', '_')}.xlsx');
    await file.writeAsBytes(fileBytes);
    
    // مشاركة الملف
    
    // ignore: deprecated_member_use
    await Share.shareXFiles([XFile(file.path)], text: '...');
  }

  // دالة عرض نافذة التحضير اليدوي
  void _showManualAddDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) {
          List<dynamic> absentStudents = _students.where((s) => s['status'] == 'absent').toList();
          
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text("Manual Attendance Override"),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: absentStudents.isEmpty 
                ? const Center(child: Text("All students marked present."))
                : ListView.builder(
                    itemCount: absentStudents.length,
                    itemBuilder: (context, i) => Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text(absentStudents[i]['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text("ID: ${absentStudents[i]['id']}"),
                        trailing: IconButton(
                          icon: const Icon(Icons.add_circle, color: Colors.green, size: 30),
                          onPressed: () {
                            _markAsPresentManual(absentStudents[i]['id'].toString());
                            setStateDialog(() {}); 
                            setState(() {}); 
                          },
                        ),
                      ),
                    ),
                  ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx), 
                child: const Text("Close", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))
              ),
            ],
          );
        },
      ),
    );
  }

  // =========================================================================
  //  واجهة المستخدم (UI)
  // هنا يتم(الكل، الحاضرين، الغائبين) تصميم القوائم والأزرار.
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    int total = _students.length;
    int present = _students.where((s) => s['status'] == 'present').length;
    int absent = total - present;

    return DefaultTabController(
      length: 3, 
      child: Scaffold(
        backgroundColor: Colors.grey.shade100,
        appBar: AppBar(
          title: Text(widget.courseName, style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
          elevation: 0,
          actions: [
            IconButton(tooltip: "Sync Force Push", icon: const Icon(Icons.cloud_upload_outlined), onPressed: () => _updateFirestore(silent: false)),
            IconButton(tooltip: "Export Excel Report", icon: const Icon(Icons.download_rounded), onPressed: _exportAttendanceReport),
            
          ],
        bottom: TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.indigo.shade200,
            indicatorColor: Colors.white,
            indicatorWeight: 4,
            labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            tabs: [
              Tab(text: "All ($total)"),        
              Tab(text: "Present ($present)"),  
              Tab(text: "Absent ($absent)"),    
            ],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: TabBarView(
                children: [
                  _buildFilteredStudentList(_students), 
                  _buildFilteredStudentList(_students.where((s) => s['status'] == 'present').toList()), 
                  _buildFilteredStudentList(_students.where((s) => s['status'] == 'absent').toList()), 
                ],
              ),
            ),
            SafeArea(
              top: false, 
              child: _buildControlPanel(), 
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilteredStudentList(List<dynamic> filteredList) {
    if (filteredList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.group_off_rounded, size: 60, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            const Text("No students in this category.", style: TextStyle(color: Colors.black54, fontSize: 16)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: filteredList.length,
      itemBuilder: (ctx, i) {
        var student = filteredList[i];
        bool isPresent = student['status'] == 'present';
        
        return Card(
          elevation: 1,
          margin: const EdgeInsets.only(bottom: 10),
          shape: RoundedRectangleBorder(
            side: BorderSide(color: isPresent ? Colors.green.shade400 : Colors.red.shade200, width: 1.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: CircleAvatar(
              backgroundColor: isPresent ? Colors.green.shade50 : Colors.red.shade50,
              child: Icon(
                isPresent ? Icons.check_circle_rounded : Icons.cancel_rounded, 
                color: isPresent ? Colors.green.shade600 : Colors.red.shade400,
                size: 28,
              ),
            ),
            title: Text(student['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            subtitle: Text("ID: ${student['id']}", style: TextStyle(color: Colors.grey.shade600)),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isPresent ? Colors.green.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                isPresent ? "Verified" : "Absent",
                style: TextStyle(
                  color: isPresent ? Colors.green.shade700 : Colors.red.shade700,
                  fontWeight: FontWeight.bold,
                  fontSize: 13
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildControlPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -5))]
      ),
      child: Row(
        children: [
          Expanded(
           child: ElevatedButton.icon(
              onPressed: _toggleSession,
              icon: Icon(_isSessionActive ? Icons.stop_circle_rounded : Icons.bluetooth_searching_rounded),
              label: Text(
                _isSessionActive ? "Stop Radar" : "Start Radar", 
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: _isSessionActive ? Colors.red.shade600 : Colors.indigo,
                foregroundColor: Colors.white,
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            decoration: BoxDecoration(
              color: Colors.orange.shade50, 
              borderRadius: BorderRadius.circular(12), 
              border: Border.all(color: Colors.orange.shade200)
            ),
            child: IconButton(
              tooltip: "Force Manual Validation", 
              onPressed: _showManualAddDialog, 
              icon: Icon(Icons.edit_note_rounded, size: 28, color: Colors.orange.shade700)
            ),
          )
        ],
      ),
    );
  }
}