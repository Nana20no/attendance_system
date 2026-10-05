import 'dart:io'; 
import 'package:flutter/material.dart'; 
import 'package:cloud_firestore/cloud_firestore.dart'; // لجلب البيانات من السيرفر
import 'package:excel/excel.dart' hide Border; // لإنشاء وتنسيق ملف الإكسيل
import 'package:path_provider/path_provider.dart'; // للوصول لمساحة التخزين في هاتف الدكتور
import 'package:share_plus/share_plus.dart'; // لمشاركة الملف (واتساب، إيميل، الخ)
import 'package:intl/intl.dart'; // لتنسيق التاريخ

class CumulativeReportScreen extends StatefulWidget { 
  final String courseId;
  final String courseName;

  const CumulativeReportScreen({super.key, required this.courseId, required this.courseName});

  @override 
  State<CumulativeReportScreen> createState() => _CumulativeReportScreenState(); 
}

class _CumulativeReportScreenState extends State<CumulativeReportScreen> { 
  final FirebaseFirestore _firestore = FirebaseFirestore.instance; 
  bool _isExporting = false;

  // =========================================================================
  //  الدالة 1: _fetchAndAggregateData (عقل التحليلات الذكية - Smart Analytics)
  //  المكتبات المستخدمة: cloud_firestore
  //  المنطق: هذه الدالة تقوم بـ 3 أشياء بضربة واحدة:
  // 1. تجلب قائمة الطلاب من المادة + كل سجلات المحاضرات السابقة في نفس الوقت (بواسطة Future.wait لتسريع الأداء).
  // 2. تمر على كل طالب، وتحسب كم مرة حضر وكم مرة غاب، وتستخرج النسبة المئوية.
  // 3. بناءً على نسبة الغياب، تعطي الطالب حالة آلية (Safe, Warning, Denied).
  //  للشرح للدكتور: "يا دكتور، هذه الدالة هي المحرك الذكي. لجعلها سريعة استخدمت (Future.wait) 
  // لجلب الطلاب وسجلات الغياب بالتوازي. ثم برمجت خوارزمية تحسب نسبة الغياب تلقائياً 
  // وتصنف الطالب إلى (محروم، مُنذر، أو آمن) حسب اللوائح."
  // =========================================================================
  Future<Map<String, dynamic>> _fetchAndAggregateData() async { 
    final courseRef = _firestore.collection('courses').doc(widget.courseId); 
    final sessionsRef = courseRef.collection('attendance_sessions').orderBy('date'); // الترتيب بالتاريخ

    // جلب الطلاب والجلسات في نفس اللحظة (Parallel Fetching)
    final results = await Future.wait([courseRef.get(), sessionsRef.get()]);

    DocumentSnapshot courseDoc = results[0] as DocumentSnapshot;
    QuerySnapshot sessionsSnap = results[1] as QuerySnapshot;

    List<dynamic> studentsList = (courseDoc.data() as Map<String, dynamic>?)?['students_list'] ?? [];
    int totalSessions = sessionsSnap.docs.length;

    // استخراج تواريخ المحاضرات لتكون أعمدة في الإكسيل لاحقاً
    List<String> sessionDates = [];
    Map<String, Map<String, dynamic>> sessionsDataMap = {};
    for (var doc in sessionsSnap.docs) {
      var data = doc.data() as Map<String, dynamic>;
      String date = data['date'] ?? 'Unknown';
      sessionDates.add(date);
      sessionsDataMap[date] = data;
    }

    List<Map<String, dynamic>> reportData = [];

    // خوارزمية الحسابات (Aggregation)
    for (var student in studentsList) {
      String uid = student['uid'] ?? '';
      String studentId = student['id'] ?? '';
      int presentCount = 0;
      Map<String, String> dailyAttendance = {}; // P or A لكل يوم

      for (String date in sessionDates) {
        Map<String, dynamic> presentStudentsMap = sessionsDataMap[date]?['present_students'] ?? {};
        
        if ((uid.isNotEmpty && presentStudentsMap.containsKey(uid)) || 
            (studentId.isNotEmpty && presentStudentsMap.containsKey(studentId))) {
          presentCount++;
          dailyAttendance[date] = 'P'; // Present
        } else {
          dailyAttendance[date] = 'A'; // Absent
        }
      }

      double attendancePercentage = totalSessions == 0 ? 0.0 : (presentCount / totalSessions) * 100;

      //  نظام الإنذارات الذكي (Automated Status)
      String status = 'Safe';
      if (totalSessions > 0) {
        if (attendancePercentage <= 25) {
          status = 'Denied';   // حرمان نسبة الحضور 25% وأقل 
        } else if (attendancePercentage <= 40) {
          status = 'Warning';  // إنذار نسبة الحضور بين 26% و 50% = تحذير
        }else {
          status = 'safe';     // نسبة الحضور أعلى من 50% = سليم (لون أخضر)
      }}

      reportData.add({
        'id': studentId.isNotEmpty ? studentId : 'N/A',
        'name': student['name'] ?? 'Unknown',
        'present': presentCount,
        'absent': totalSessions - presentCount,
        'attendance_percentage': attendancePercentage,
        'daily_attendance': dailyAttendance,
        'status': status,
      });
    }

    // ترتيب الطلاب أبجدياً
    reportData.sort((a, b) => a['name'].toString().compareTo(b['name'].toString()));

    return {
      'totalSessions': totalSessions,
      'sessionDates': sessionDates,
      'reportData': reportData,
    };
  }

  // =========================================================================
  //  الدالة 2: _exportMasterReport (مُصدِّر التقارير الخارق)
  //  المكتبات المستخدمة: excel + path_provider + share_plus
  //  المنطق: هذه الدالة تأخذ البيانات التي حسبناها فوق، وتنشئ ملف إكسيل حقيقي من الصفر.
  // تبني أعمدة لكل تاريخ محاضرة، وتضع P أو A، وتضيف نسبة الغياب، وتحفظ الملف في الهاتف للمشاركة.
  //  للشرح للدكتور: "النظام لا يعرض البيانات فقط، بل يصدر (Master Ledger). 
  // برمجت خوارزمية تبني أعمدة الإكسيل ديناميكياً (تزيد مع كل محاضرة جديدة)، وتضع 
  // إيموجي يوضح حالة الطالب، ثم أستخدم مكتبة (share_plus) لإرسال الملف لإدارة القسم."
  // =========================================================================
  Future<void> _exportMasterReport(List<Map<String, dynamic>> reportData, int totalSessions, List<String> sessionDates) async { 
    setState(() => _isExporting = true); 
    try { 
      var excel = Excel.createExcel(); 
      excel.rename('Sheet1', 'Master Ledger'); 
      Sheet sheetObject = excel['Master Ledger'];

      String currentDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
      
      // الترويسة الرئيسية
      sheetObject.appendRow([TextCellValue('Course:'), TextCellValue(widget.courseName), TextCellValue('Report Date:'), TextCellValue(currentDate)]);
      sheetObject.appendRow([TextCellValue('Total Recorded Sessions:'), TextCellValue(totalSessions.toString())]);
      sheetObject.appendRow([]); 

      // 📅 بناء عناوين الأعمدة ديناميكياً
      List<CellValue> headers = [TextCellValue('Student ID'), TextCellValue('Student Name')];
      for (String date in sessionDates) {
        String shortDate = date.split(' – ').first; // أخذ التاريخ بدون الوقت لتوفير المساحة
        headers.add(TextCellValue(shortDate));
      }
      headers.addAll([TextCellValue('Present'), TextCellValue('Absent'), TextCellValue('Rate (%)'), TextCellValue('System Status')]);
      sheetObject.appendRow(headers);

      // تعبئة بيانات الطلاب
      for (var row in reportData) {
        List<CellValue> excelRow = [
          TextCellValue(row['id'].toString()), 
          TextCellValue(row['name'])
        ];

        // تعبئة (P) و (A) حسب كل تاريخ
        for (String date in sessionDates) {
          excelRow.add(TextCellValue(row['daily_attendance'][date]));
        }

        double rate = row['attendance_percentage'];
        
        // إضافة الإيموجي للحالة في الإكسيل
        String excelStatus = row['status'] == 'Denied' ? 'Denied ❌' 
                           : row['status'] == 'Warning' ? 'Warning ⚠️' 
                           : 'Safe ✅';

        excelRow.addAll([
          TextCellValue(row['present'].toString()), 
          TextCellValue(row['absent'].toString()), 
          TextCellValue("${rate.toStringAsFixed(1)}%"),
          TextCellValue(excelStatus) // عمود الإنذار
        ]);

        sheetObject.appendRow(excelRow);
      }

      var fileBytes = excel.save();
      if (fileBytes == null) throw "Failed to generate Excel file";

      // حفظ الملف في مساحة الهاتف المؤقتة
      var directory = await getApplicationDocumentsDirectory();
      File file = File('${directory.path}/MasterLedger_${widget.courseName.replaceAll(' ', '_')}.xlsx');
      await file.writeAsBytes(fileBytes);
      
      // مشاركة الملف
      
      // ignore: deprecated_member_use
      await Share.shareXFiles([XFile(file.path)], text: '...');

    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("❌ Export error: $e")));
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  // =========================================================================
  // 👨‍💻 الدالة 3: _getStatusColor (تلوين الحالات)
  // 🧠 المنطق: دالة مساعدة (Helper) صغيرة لإعطاء لون لكل حالة أكاديمية.
  // =========================================================================
  Color _getStatusColor(String status) { 
    if (status == 'Denied') return Colors.red.shade700; 
    if (status == 'Warning') return Colors.orange.shade700; 
    return Colors.green.shade700; 
  }

  // =========================================================================
  // 🎨 بناء واجهة المستخدم (UI) - استخدام FutureBuilder
  // 🧠 المنطق: بما أن الحسابات والتحليلات تأخذ أجزاء من الثانية، نستخدم (FutureBuilder) 
  // ليقوم بعرض (دائرة تحميل) حتى تنتهي الدالة الأولى من حساب كل شيء، ثم يعرض الجدول (DataTable).
  // =========================================================================
  @override 
  Widget build(BuildContext context) { 
    return FutureBuilder<Map<String, dynamic>>( 
      future: _fetchAndAggregateData(), 
      builder: (context, snapshot) { 
        bool hasData = snapshot.hasData && !snapshot.hasError; 
        int totalSessions = hasData ? snapshot.data!['totalSessions'] as int : 0; 
        List<String> sessionDates = hasData ? snapshot.data!['sessionDates'] as List<String> : []; 
        List<Map<String, dynamic>> reportData = hasData ? snapshot.data!['reportData'] as List<Map<String, dynamic>> : [];

        return Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
            title: const Text("Smart Analytics", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            backgroundColor: Colors.indigo,
            foregroundColor: Colors.white,
            actions: [
              _isExporting 
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                )
              : IconButton(
                  tooltip: "Export Master Ledger",
                  icon: const Icon(Icons.file_download),
                  onPressed: !hasData || reportData.isEmpty ? null : () => _exportMasterReport(reportData, totalSessions, sessionDates),
                )
            ],
          ),
          body: snapshot.connectionState == ConnectionState.waiting
              ? const Center(child: CircularProgressIndicator(color: Colors.indigo))
              : snapshot.hasError
                  ? Center(child: Text("Error generating report: ${snapshot.error}"))
                  : reportData.isEmpty
                      ? const Center(child: Text("No enrolled students found to generate report."))
                      : Column(
                          children: [
                            // 💡 البطاقات العلوية التي تعرض ملخص الإحصائيات (المحاضرات، الطلاب، المحرومين)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              color: Colors.indigo.shade50,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceAround,
                                children: [
                                  _buildSummaryStat("Lectures", totalSessions.toString(), Colors.indigo),
                                  _buildSummaryStat("Students", reportData.length.toString(), Colors.blue.shade700),
                                  _buildSummaryStat("Denied", reportData.where((r) => r['status'] == 'Denied').length.toString(), Colors.red.shade700),
                                ],
                              ),
                            ),
                            // 💡 الجدول التحليلي (DataTable) الذي يمكن سحبه لليمين واليسار
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.vertical,
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: DataTable(
                                    headingRowColor: WidgetStateProperty.all(Colors.grey.shade100),
                                    columnSpacing: 20,
                                    columns: const [
                                      DataColumn(label: Text("Name", style: TextStyle(fontWeight: FontWeight.bold))),
                                      DataColumn(
                                        tooltip: "Present", 
                                        label: Text("P", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green))
                                      ),
                                      DataColumn(
                                        tooltip: "Absent", 
                                        label: Text("A", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red))
                                      ),
                                      DataColumn(label: Text("Rate", style: TextStyle(fontWeight: FontWeight.bold))),
                                      DataColumn(label: Text("Status", style: TextStyle(fontWeight: FontWeight.bold))),
                                    ],
                                    rows: reportData.map((row) {
                                      double rate = row['attendance_percentage'];
                                      String status = row['status'];
                                      return DataRow(
                                        cells: [
                                          DataCell(Text(row['name'])),
                                          DataCell(Text(row['present'].toString(), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green))),
                                          DataCell(Text(row['absent'].toString(), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red))),
                                          DataCell(Text("${rate.toStringAsFixed(0)}%")),
                                          DataCell(
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: _getStatusColor(status).withValues(alpha: 0.1),
                                                borderRadius: BorderRadius.circular(8),
                                                border: Border.all(color: _getStatusColor(status).withValues(alpha: 0.5))
                                              ),
                                              child: Text(status, style: TextStyle(color: _getStatusColor(status), fontWeight: FontWeight.bold, fontSize: 12)),
                                            )
                                          ),
                                        ],
                                      );
                                    }).toList(),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
        );
      },
    );
  }

  // دالة مساعدة لرسم الأرقام الثلاثة أعلى الشاشة
  Widget _buildSummaryStat(String label, String value, Color color) { 
    return Column( 
      children: [ 
        Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)), 
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.bold)), 
      ],
    ); 
  } 
}