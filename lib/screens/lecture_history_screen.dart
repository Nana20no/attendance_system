import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import '../mixins/alert_mixin.dart';

class LectureHistoryScreen extends StatefulWidget {
  final String courseId;
  final String courseName;

  const LectureHistoryScreen({super.key, required this.courseId, required this.courseName});

  @override
  State<LectureHistoryScreen> createState() => _LectureHistoryScreenState();
}

class _LectureHistoryScreenState extends State<LectureHistoryScreen> with AlertMixin {
  bool _isExporting = false;
  // =========================================================================
//  الدالة 1: _exportSessionToExcel (تصدير محاضرة واحدة)
//  المنطق: تأخذ بيانات محاضرة معينة وتحولها لملف إكسيل، ثم تفتحه في قائمة المشاركة في الهاتف.
//  الدوال: Excel.createExcel(), shareXFiles()
//   النظام يوفر (Granular Reporting)، أي يمكنني تصدير تقرير لمحاضرة 
// واحدة محددة بتفاصيل وقت حضور كل طالب، ومشاركته فوراً عبر أي وسيلة"
// =========================================================================
  
  Future<void> _exportSessionToExcel(Map<String, dynamic> sessionData) async {
    setState(() => _isExporting = true);
    try {
      var excel = Excel.createExcel();
      excel.rename('Sheet1', 'Session Attendance');
      Sheet sheetObject = excel['Session Attendance'];
      
      String sessionDate = sessionData['date'] ?? 'Unknown Date';
      String safeDate = sessionDate.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '-');
      String fileName = 'Session_${widget.courseName}_$safeDate.xlsx';
      
      // كتابة الترويسة
      sheetObject.appendRow([TextCellValue('Course:'), TextCellValue(widget.courseName)]);
      sheetObject.appendRow([TextCellValue('Session Date:'), TextCellValue(sessionDate)]);
      sheetObject.appendRow([]); // سطر فارغ
      
      // كتابة عناوين الأعمدة
      sheetObject.appendRow([
        TextCellValue('Student ID'), 
        TextCellValue('Student Name'), 
        TextCellValue('Timestamp')
      ]);

      // جلب قائمة الحضور
      Map<String, dynamic> presentStudents = sessionData['present_students'] ?? {};
      List<dynamic> studentsList = presentStudents.values.toList();

      // تعبئة بيانات الطلاب
      for (var student in studentsList) {
        String timeString = "Unknown Time";
        if (student['timestamp'] is Timestamp) {
          timeString = DateFormat('hh:mm a').format((student['timestamp'] as Timestamp).toDate());
        } else if (student['timestamp'] != null) {
          timeString = student['timestamp'].toString();
        }

        sheetObject.appendRow([
          TextCellValue(student['student_id'].toString()),
          TextCellValue(student['student_name'] ?? 'Unknown'),
          TextCellValue(timeString)
        ]);
      }

      // حفظ الملف محلياً
      var fileBytes = excel.save();
      if (fileBytes == null) throw "Failed to generate Excel file";

      var directory = await getApplicationDocumentsDirectory();
      File localFile = File('${directory.path}/$fileName');
      await localFile.writeAsBytes(fileBytes);
      
     

      // مشاركة الملف (تجاهلنا التحذير الأصفر هنا لكي لا يزعجك)
      // ignore: deprecated_member_use
      await Share.shareXFiles([XFile(localFile.path)], text: 'Attendance Report for ${widget.courseName} on $sessionDate');
      
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("❌ Export error: $e")));
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }
 
  // =========================================================================
//  الدالة 2: _showSessionDetails (عرض التفاصيل في BottomSheet)
//  المنطق: عرض قائمة الطلاب الذين حضروا في جلسة معينة داخل نافذة منبثقة (Modal Bottom Sheet).
// =========================================================================
  void _showSessionDetails(BuildContext context, Map<String, dynamic> sessionData) {
    Map<String, dynamic> presentStudents = sessionData['present_students'] ?? {};
    List<dynamic> studentsList = presentStudents.values.toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // 🌟 استخدمنا Expanded لحل مشكلة الشريط الأصفر والأسود (Overflow)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Session: ${sessionData['date'] ?? 'Unknown Date'}", 
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.indigo),
                              softWrap: true,
                            ),
                            Text("${studentsList.length} Students Present", style: const TextStyle(color: Colors.black54)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _isExporting
                      ? const CircularProgressIndicator()
                      : ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade700,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () {
                            Navigator.pop(context); // إغلاق النافذة السفلية قبل التصدير
                            _exportSessionToExcel(sessionData); // استدعاء دالة التصدير
                          },
                          icon: const Icon(Icons.file_download, size: 20),
                          label: const Text("Export"),
                        )
                    ],
                  ),
                ),
                Expanded(
                  child: studentsList.isEmpty 
                  ? const Center(child: Text("No students were present."))
                  : ListView.separated(
                      controller: scrollController,
                      itemCount: studentsList.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        var student = studentsList[index];
                        String timeString = "Unknown Time";
                        if (student['timestamp'] is Timestamp) {
                          timeString = DateFormat('hh:mm a').format((student['timestamp'] as Timestamp).toDate());
                        } else if (student['timestamp'] != null) {
                          timeString = student['timestamp'].toString();
                        }

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.green.shade100,
                            child: const Icon(Icons.check, color: Colors.green),
                          ),
                          title: Text(student['student_name'] ?? 'Unknown Name', style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text("ID: ${student['student_id']}"),
                          trailing: Text(timeString, style: const TextStyle(color: Colors.black54, fontWeight: FontWeight.bold)),
                        );
                      },
                    ),
                ),
              ],
            );
          },
        );
      },
    );
  }
 
 // =========================================================================
// الدالة 3: الـ StreamBuilder (أهم جزء في الشاشة)
//  المنطق: الاستماع الحي (Real-time) لجدول `attendance_sessions` في فايربيس.
// للشرح: "هنا استخدمت StreamBuilder ليعرض تاريخ المحاضرات أولاً بأول. لو أضاف الدكتور 
// محاضرة جديدة، ستظهر فوراً في القائمة بدون عمل Refresh."
// =========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: Text("${widget.courseName} History", style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('courses')
            .doc(widget.courseId)
            .collection('attendance_sessions')
            .orderBy('date', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return const Center(child: Text("Failed to load history."));
          
          final sessions = snapshot.data?.docs ?? [];
          if (sessions.isEmpty) {
            return const Center(
              child: Text("No attendance sessions recorded yet.", style: TextStyle(color: Colors.black54, fontSize: 16)),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              var sessionData = sessions[index].data() as Map<String, dynamic>;
              bool isActive = sessionData['is_active'] ?? false;
              int presentCount = (sessionData['present_students'] as Map<String, dynamic>? ?? {}).length;

              // 🌟 التغيير هنا: قمنا بتغليف الـ Card بـ Dismissible
              return Dismissible(
                key: Key(sessions[index].id), // مفتاح فريد يعتمد على ID الوثيقة في فايربيس
                direction: DismissDirection.endToStart, // السحب من اليمين لليسار
                background: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade700, 
                    borderRadius: BorderRadius.circular(12)
                  ),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: const Icon(Icons.delete_forever, color: Colors.white, size: 30),
                ),
                // رسالة التأكيد قبل الحذف
                confirmDismiss: (direction) async {
  return await showConfirmationDialog(
    context,
    title: "Delete Session?",
    content: "This will permanently delete this lecture's attendance record.",
    confirmText: "Delete",
  );
},
                // الحذف الفعلي من قاعدة البيانات بعد الموافقة
                onDismissed: (direction) async {
                  try {
                    await FirebaseFirestore.instance
                        .collection('courses')
                        .doc(widget.courseId)
                        .collection('attendance_sessions')
                        .doc(sessions[index].id)
                        .delete();
                  } catch (e) {
                    debugPrint("Error deleting session: $e");
                  }
                },
                child: Card(
                  elevation: 2,
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    leading: CircleAvatar(
                      backgroundColor: isActive ? Colors.red.shade100 : Colors.indigo.shade100,
                      child: Icon(isActive ? Icons.sensors : Icons.event_available, color: isActive ? Colors.red.shade700 : Colors.indigo),
                    ),
                    title: Text(sessionData['date'] ?? 'Unknown Date', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    subtitle: Text(isActive ? "Radar currently active..." : "Session Closed"),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.green.shade200)
                      ),
                      child: Text("$presentCount Present", style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.bold)),
                    ),
                    onTap: () => _showSessionDetails(context, sessionData),
                  ),
                ),
              ); // نهاية الـ Dismissible
            },
          );
        },
      ),
    );
  }
}