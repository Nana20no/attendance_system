import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart'; // مكتبة اختيار الملفات من الهاتف
import 'package:cloud_firestore/cloud_firestore.dart'; // مكتبة قاعدة البيانات
import 'package:flutter/foundation.dart'; // مكتبة تدعم دالة (compute) للعمليات الكبيره
import '../services/file_parser_service.dart'; 
import '../mixins/alert_mixin.dart'; 
import 'attendance_scanner_screen.dart';
import 'lecture_history_screen.dart';
import 'cumulative_report_screen.dart';
import 'student_roster_screen.dart';
import 'report_vault_screen.dart';

class CourseHubScreen extends StatefulWidget {
  final String courseId;
  final String courseName;
  final int enrolledCount;

  const CourseHubScreen({
    super.key,
    required this.courseId,
    required this.courseName,
    required this.enrolledCount,
  });

  @override
  State<CourseHubScreen> createState() => _CourseHubScreenState();
}

class _CourseHubScreenState extends State<CourseHubScreen> with AlertMixin {
  bool _isUploading = false; // للتحكم في ظهور دائرة التحميل أثناء رفع الإكسيل
  int _currentEnrolledCount = 0; // لعرض عدد الطلاب المسجلين حالياً

  @override
  void initState() {
    super.initState();
    _currentEnrolledCount = widget.enrolledCount;
  }

  // =========================================================================
  //  الدالة 1: _uploadExcelRoster (استيراداو تحميل ملف الإكسيل)
  // المكتباة: file_picker + cloud_firestore + foundation (compute)
  //  المنطق: نفتح مدير الملفات ليختار الدكتور ملف الإكسيل. قراءة الإكسيل عملية "ثقيلة" 
  // قد تجمّد الشاشة، لذلك نستخدم دالة (compute) لتقوم بفك تشفير الإكسيل في "مسار خلفي" (Background Isolate).
  // وبعد تجهيز القائمة، نرفعها دفعة واحدة إلى Firebase.
  //  للشرح للدكتور: "يا دكتور، لكي لا يتجمد التطبيق أثناء قراءة ملف إكسيل به 1000 طالب، 
  // استخدمت تقنية الـ (Isolates) عبر دالة (compute). هذه التقنية تفصل عملية الحسابات الثقيلة 
  // عن واجهة المستخدم (UI Thread)، وبعدها أرفع القائمة لـ Firestore."
  // =========================================================================
  Future<void> _uploadExcelRoster() async {
    try {
      // 1. فتح مدير الملفات لاختيار ملف بصيغة xlsx
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        withData: true, 
      );

      if (result == null || result.files.single.bytes == null) return; 

      setState(() => _isUploading = true); // تشغيل علامة التحميل

      final bytes = result.files.single.bytes!;
      
      //  هنا السحر الهندسي: إرسال البايتات لدالة خارجية لتعالجها في الخلفية (Isolate)
      List<Map<String, dynamic>> parsedStudents = await compute(parseExcelFile, bytes);

      if (parsedStudents.isEmpty) {
        if (!mounted) return;
        showAppSnackBar(context, "The file is empty or formatted incorrectly.", isError: true);
        setState(() => _isUploading = false);
        return;
      }

      // 3. تحديث قائمة الطلاب في قاعدة البيانات (Firebase)
      await FirebaseFirestore.instance
          .collection('courses')
          .doc(widget.courseId)
          .update({'students_list': parsedStudents});

      if (!mounted) return;
      
      // 4. تحديث الواجهة لعرض العدد الجديد للطلاب
      setState(() {
        _currentEnrolledCount = parsedStudents.length;
        _isUploading = false;
      });
      
      showAppSnackBar(context, "✅ Successfully uploaded ${parsedStudents.length} students!", isError: false);

    } catch (e) {
      if (!mounted) return;
      setState(() => _isUploading = false);
      showAppSnackBar(context, "Failed to upload roster: $e");
    }
  }

  // =========================================================================
  //  بناء واجهة المستخدم (UI Build)
  //  المنطق: الشاشة مقسمة لجزئين: الجزء العلوي (Header) يعرض اسم المادة وعدد الطلاب، 
  // والجزء السفلي (Grid) يعرض 6 أزرار للتحكم في المادة.
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50, 
      appBar: AppBar(
        title: Text(widget.courseName, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Column(
        children: [
          // 💡 الجزء العلوي (Header): يعرض إجمالي الطلاب بطريقة ديناميكية
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            decoration: const BoxDecoration(
              color: Colors.indigo,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.school_rounded, color: Colors.white, size: 40),
                ),
                const SizedBox(height: 12),
                Text(
                  "Total Enrolled",
                  style: TextStyle(color: Colors.indigo.shade100, fontSize: 16),
                ),
                Text(
                  "$_currentEnrolledCount Students",
                  style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 20),

          // =========================================================================
          // 💡 شبكة الأزرار (Dashboard Grid)
          // 🎤 للشرح للدكتور: "قمت ببرمجة شروط (Validation) هنا. مثلاً، لا يمكن للدكتور 
          // فتح شاشة الرادار (Start Attendance) إذا كان عدد الطلاب 0، النظام سيمنعه ويطلب 
          // منه رفع ملف إكسيل أولاً لتجنب الأخطاء."
          // =========================================================================
          Expanded(
            child: GridView.count(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              crossAxisCount: 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: 0.95, 
              children: [
                
                // زر 1: تشغيل الرادار
                _buildGridCard(
                  title: "Start Attendance", 
                  icon: Icons.radar_rounded,
                  color: Colors.teal,
                  onTap: () {
                    // حماية برمجية: نمنع فتح الرادار لو مفيش طلاب
                    if (_currentEnrolledCount == 0) {
                      showAppSnackBar(context, "Please import a roster first!", isError: true);
                      return;
                    }
                    Navigator.push(context, MaterialPageRoute(builder: (_) => AttendanceScannerScreen(courseId: widget.courseId, courseName: widget.courseName)));
                  },
                ),
                
                // زر 2: استيراد الإكسيل
                _buildGridCard(
                  title: "Import Students", 
                  icon: Icons.upload_file_rounded,
                  color: Colors.purple,
                  isLoading: _isUploading,
                  onTap: _isUploading ? null : _uploadExcelRoster,
                ),
                
                // زر 3: سجل المحاضرات
                _buildGridCard(
                  title: "Lectures History", 
                  icon: Icons.history_edu_rounded,
                  color: Colors.blue,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LectureHistoryScreen(courseId: widget.courseId, courseName: widget.courseName))),
                ),
                
                // زر 4: التقرير الذكي
                _buildGridCard(
                  title: "Cumulative Report", 
                  icon: Icons.analytics_rounded,
                  color: Colors.orange,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CumulativeReportScreen(courseId: widget.courseId, courseName: widget.courseName))),
                ),
                
                // زر 5: إدارة الطلاب
                _buildGridCard(
                  title: "Manage Students", 
                  icon: Icons.manage_accounts_rounded,
                  color: Colors.blueGrey,
                  onTap: () {
                     if (_currentEnrolledCount == 0) {
                      showAppSnackBar(context, "Roster is empty. Import Excel first.", isError: true);
                      return;
                    }
                    Navigator.push(context, MaterialPageRoute(builder: (_) => StudentRosterScreen(courseId: widget.courseId, courseName: widget.courseName)));
                  },
                ),
                
                // زر 6: التقارير المحفوظة
                _buildGridCard(
                  title: "Saved Reports", 
                  icon: Icons.folder_special_rounded,
                  color: Colors.indigo,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReportVaultScreen(courseId: widget.courseId, courseName: widget.courseName))),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // 👨‍💻 الدالة 2: _buildGridCard (تصميم البطاقات)
  // 🧠 المنطق: بدلاً من تكرار كود التصميم 6 مرات، قمت بإنشاء دالة مساعدة تأخذ (الاسم، الأيقونة، اللون، والحدث) 
  // وتقوم برسم البطاقة (Reusable Widget). هذا يجعل الكود نظيفاً وسهل التعديل (Clean Code).
  // =========================================================================
  Widget _buildGridCard({
    required String title,
    required IconData icon,
    required MaterialColor color,
    required VoidCallback? onTap,
    bool isLoading = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, 5)) 
          ],
          border: Border.all(color: color.shade50, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center, 
          crossAxisAlignment: CrossAxisAlignment.center, 
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: color.shade50, shape: BoxShape.circle),
              child: isLoading 
                ? SizedBox(width: 32, height: 32, child: CircularProgressIndicator(color: color.shade700, strokeWidth: 3))
                : Icon(icon, size: 32, color: color.shade700),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0), 
              child: Text(
                title,
                textAlign: TextAlign.center, 
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
              ),
            ),
          ],
        ),
      ),
    );
  }
}