import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // للتعامل مع قاعدة البيانات
import 'package:firebase_auth/firebase_auth.dart'; // لمعرفة من هو الدكتور الذي سجل دخوله
import '../mixins/alert_mixin.dart'; // التنبيهات الموحدة
import 'login_screen.dart';
import 'course_hub_screen.dart';
import 'student_management_screen.dart'; 
import '../constants/app_constants.dart';

class DoctorDashboard extends StatefulWidget {
  const DoctorDashboard({super.key});
  @override
  State<DoctorDashboard> createState() => _DoctorDashboardState();
}

class _DoctorDashboardState extends State<DoctorDashboard> with AlertMixin {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // =========================================================================
  //  الدالة 1: _addNewCourse (إضافة مادة جديدة)
  //  المكتبات المستخدمة: cloud_firestore + firebase_auth
  //  المنطق: نأخذ اسم المادة، ونفتح "ملف جديد" (Document) في مجموعة (courses).
  // السر هنا هو أننا نحفظ (uid) الخاص بالدكتور داخل ملف المادة، لكي لا تظهر مواده لدكتور آخر!
  //   لكي أفصل مواد الدكاترة عن بعضها، كل مادة أقوم بإنشائها
  // أربطها بـ (doctor_id) الخاص بالمستخدم الحالي، هكذا كل دكتور يرى مواده فقط."
  // =========================================================================
  Future<void> _addNewCourse(String name) async {
    if (name.trim().isEmpty) return;
    try {
      await _firestore.collection('courses').add({
        'course_name': name.trim(),
        'doctor_id': FirebaseAuth.instance.currentUser?.uid, // <--- ربط المادة بالدكتور
        'students_list': [], // قائمة الطلاب تبدأ فارغة
      });
      if (!mounted) return;
      showAppSnackBar(context, "✅ Module profile initialized successfully.", isError: false);
    } catch (e) {
      showAppSnackBar(context, "❌ Failed to initialize module: $e");
    }
  }

  // =========================================================================
  //  الدالة 2: _editCourseName (تعديل اسم المادة)
  // المكتبات المستخدمة: cloud_firestore (دالة update)
  //  المنطق: تظهر نافذة منبثقة (Dialog) نكتب فيها الاسم الجديد، ثم نرسل أمر 
  // (update) لقاعدة البيانات لتغيير حقل (course_name) فقط في هذه المادة المحددة.
  // =========================================================================
  

  // =========================================================================
  //  الدالة 3: _deleteCourse (حذف المادة نهائياً)
  //  المكتبات المستخدمة: AlertMixin (الدالة الموحدة) + cloud_firestore (دالة delete)
  //  المنطق: قبل الحذف، نستخدم الدالة الموحدة التي برمجناها (showConfirmationDialog)
  // كطبقة حماية لتأكيد رغبة الدكتور بالحذف. لو وافق، نرسل أمر (delete) للسيرفر.
  // =========================================================================
  Future<void> _deleteCourse(String docId, String courseName) async {
    bool confirmDelete = await showConfirmationDialog(
      context,
      title: "Delete Module?",
      content: "Are you sure you want to permanently delete '$courseName'?\n\nThis will remove the roster and all access to it.",
      confirmText: "Delete Permanently",
    );

    if (confirmDelete) {
      try {
        await _firestore.collection('courses').doc(docId).delete();
        if (mounted) showAppSnackBar(context, "✅ Module '$courseName' deleted.", isError: false);
      } catch (e) {
        if (mounted) showAppSnackBar(context, "❌ Deletion failed.");
      }
    }
  }

  // =========================================================================
  //  الدالة 4: _logout (تسجيل الخروج)
  //  المكتبات المستخدمة: firebase_auth
  //  المنطق: مسح جلسة المستخدم الحالي والعودة به إلى شاشة تسجيل الدخول.
  // =========================================================================
  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  // =========================================================================
  //  واجهة المستخدم (UI) - استخدام StreamBuilder
  //  المكتبات المستخدمة: cloud_firestore (دالة snapshots)
  //  المنطق (مهم جداً للمناقشة): نحن هنا لا نستخدم (Future) الذي يجلب البيانات مرة واحدة،
  // بل نستخدم (StreamBuilder). الـ Stream هو عبارة عن "أنبوب مفتوح" بين التطبيق والفايربيس.
  // أي تغيير يحدث في السيرفر (إضافة، تعديل، حذف) سيظهر في واجهة الدكتور فوراً (Real-time).
  // 🎤 للشرح للدكتور: "يا دكتور، واجهة المواد هنا (Reactive)، استخدمت (StreamBuilder) 
  // يستمع للتحديثات الحية. لو قمت بتعديل اسم المادة من جهاز آخر، سيتغير الاسم هنا فوراً 
  // بدون الحاجة لعمل تحديث (Refresh) للصفحة."
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text("Doctor Dashboard", style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          // 💡 زر شاشة إدارة الأجهزة (Device Management) التي برمجناها للطوارئ
          IconButton(
            tooltip: "Device Management",
            icon: const Icon(Icons.admin_panel_settings), 
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StudentManagementScreen()))
          ),
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        // 💡 الاستماع الحي (Live Stream) للمواد الخاصة بهذا الدكتور فقط
        stream: _firestore
            .collection('courses')
            .where('doctor_id', isEqualTo: FirebaseAuth.instance.currentUser?.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(child: Text("Connection interrupted. Ensure network connection."));
          }
          
          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.class_outlined, size: 80, color: Colors.indigo.shade200),
                  const SizedBox(height: 16),
                  const Text("No modules assigned.", style: TextStyle(color: Colors.black54, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text("Tap (+) to initialize a new module.", style: TextStyle(color: Colors.black45)),
                ],
              )
            );
          }
          
          //  رسم قائمة المواد على شكل بطاقات (Cards)
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              var doc = docs[i];
              var data = doc.data() as Map<String, dynamic>;
              List dynamicList = data['students_list'] ?? [];
              String cName = data['course_name'] ?? 'Unnamed Course';
              
              return Card(
                elevation: 1.5,
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    // 💡 عند الضغط، ننتقل لـ "CourseHubScreen" ونمرر لها ID المادة لكي تعرف أي مادة ستتحكم بها
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CourseHubScreen(
                          courseId: doc.id,
                          courseName: cName,
                          enrolledCount: dynamicList.length,
                        )
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors.indigo.shade50,
                        child: const Icon(Icons.folder_shared_rounded, color: Colors.indigo),
                      ),
                      title: Text(cName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      subtitle: Text("Enrolled Roster: ${dynamicList.length} Students", style: TextStyle(color: Colors.grey.shade600)),
                      
                      // 💡 أيقونة الخيارات ⁝ (تعديل / حذف)
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert_rounded, color: Colors.grey),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        onSelected: (value) {
                           if (value == 'delete') {
                            _deleteCourse(doc.id, cName);
                          }
                        },
                        itemBuilder: (context) => [
                          
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_rounded, color: Colors.red.shade700, size: 20),
                                const SizedBox(width: 12),
                                const Text("Delete Course", style: TextStyle(color: Colors.red)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
      //  الزر العائم (زر الـ + في أسفل الشاشة) لفتح نافذة إضافة مادة
     floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text("New Course", style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: () async { // 💡 أضفنا async هنا
        
          // 💡 1. جلب مواد الدكتور الحالية من قاعدة البيانات لمعرفة ما تم إنشاؤه مسبقاً
          var snapshot = await _firestore
              .collection('courses')
              .where('doctor_id', isEqualTo: FirebaseAuth.instance.currentUser?.uid)
              .get();

          List<String> existingCourses = snapshot.docs.map((doc) => 
            (doc.data())['course_name'].toString().toLowerCase()
          ).toList();

          // 💡 2. فلترة قائمة القسم: إظهار المواد التي لم يتم إنشاؤها فقط
          List<String> availableCourses = AppConstants.departmentCourses
              .where((course) => !existingCourses.contains(course.toLowerCase()))
              .toList();

          if (availableCourses.isEmpty) {
            if (context.mounted) showAppSnackBar(context, "✅ All department courses are already created.", isError: false);
            return;
          }

          String? selectedCourse;
          
          if (!context.mounted) return; // حماية ضد الأخطاء الصفراء
          
          showDialog(
            context: context, 
            builder: (ctx) => StatefulBuilder(
              builder: (context, setStateDialog) {
                return AlertDialog(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: const Text("Create New Course", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo)), 
                  content: DropdownButtonFormField<String>(
                    initialValue: selectedCourse, // 💡 تم تصحيح التحذير هنا
                    decoration: InputDecoration(
                      labelText: "Select Module",
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))
                    ),
                    items: availableCourses.map((String course) {
                      return DropdownMenuItem<String>(
                        value: course,
                        child: Text(course.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                      );
                    }).toList(),
                    onChanged: (val) => setStateDialog(() => selectedCourse = val),
                  ), 
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                      onPressed: () { 
                        if (selectedCourse != null) {
                          _addNewCourse(selectedCourse!); 
                          Navigator.pop(ctx); 
                        }
                      }, 
                      child: const Text("Create")
                    )
                  ]
                );
              }
            )
          );
        },
      ),
    );
  }
}