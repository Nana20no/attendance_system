import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../mixins/alert_mixin.dart';

class StudentRosterScreen extends StatelessWidget with AlertMixin {
  final String courseId;
  final String courseName;

  const StudentRosterScreen({super.key, required this.courseId, required this.courseName});

  // دالة الحذف من Firestore
  Future<void> _removeStudent(BuildContext context, Map<String, dynamic> studentData) async {
    try {
      // نستخدم FieldValue.arrayRemove لحذف الطالب من المصفوفة بدقة
      await FirebaseFirestore.instance.collection('courses').doc(courseId).update({
        'students_list': FieldValue.arrayRemove([studentData])
      });
      if (context.mounted) {
        showAppSnackBar(context, "✅ Student '${studentData['name']}' removed from course.", isError: false);
      }
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(context, "❌ Failed to remove student: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: Text("Manage Student: $courseName", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('courses').doc(courseId).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text("Error loading roster."));
          }

          var courseData = snapshot.data!.data() as Map<String, dynamic>?;
          List<dynamic> studentsList = courseData?['students_list'] ?? [];

          if (studentsList.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.person_off_rounded, size: 80, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  const Text("No students enrolled yet.", style: TextStyle(color: Colors.black54, fontSize: 18)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: studentsList.length,
            itemBuilder: (context, index) {
              var student = studentsList[index] as Map<String, dynamic>;
              String studentId = student['id'] ?? 'Unknown ID';
              String studentName = student['name'] ?? 'Unknown Name';

              // أداة Dismissible للسحب والحذف
              return Dismissible(
                key: Key(studentId + studentName), // مفتاح فريد لكل طالب
                direction: DismissDirection.endToStart, // السحب من اليمين لليسار
                background: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade600,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text("Delete", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      SizedBox(width: 8),
                      Icon(Icons.delete_sweep_rounded, color: Colors.white, size: 30),
                    ],
                  ),
                ),
                // إظهار رسالة تأكيد قبل الحذف النهائي
                // داخل StudentRosterScreen
              confirmDismiss: (direction) async {
  return await showConfirmationDialog(
    context,
    title: "Confirm Removal",
    content: "Are you sure you want to remove '$studentName' from this course?",
    confirmText: "Remove",
  );
},
                onDismissed: (direction) {
                  _removeStudent(context, student);
                },
                child: Card(
                  elevation: 1,
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.blueGrey.shade50,
                      child: const Icon(Icons.person, color: Colors.blueGrey),
                    ),
                    title: Text(studentName, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text("ID: $studentId"),
                    trailing: const Icon(Icons.swipe_left_rounded, color: Colors.grey, size: 20),
                  ),
                ),
              );
            },
          );
        },
      ),
    
    //33 
    // أضف هذا الجزء داخل Scaffold
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_rounded),
        label: const Text("Add Student"),
        onPressed: () {
          var nameCtrl = TextEditingController();
          var idCtrl = TextEditingController();
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text("Manual Student Entry"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "Student Name")),
                  const SizedBox(height: 12),
                  TextField(controller: idCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "Student ID")),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
                ElevatedButton(
                  onPressed: () async {
                    String newName = nameCtrl.text.trim();
                    String newId = idCtrl.text.trim();
                    
                    if (newName.isNotEmpty && newId.isNotEmpty) {
                      
                      String cleanNewId = newId.replaceAll(RegExp(r'[^0-9]'), '');
                      
                      var courseDoc = await FirebaseFirestore.instance.collection('courses').doc(courseId).get();
                      
                      // 💡 إصلاح التحذير: التأكد من أن النافذة لم تُغلق أثناء انتظار السيرفر
                      if (!context.mounted || !ctx.mounted) return;

                      List<dynamic> currentStudents = courseDoc.data()?['students_list'] ?? [];

                      bool isDuplicate = currentStudents.any((s) {
                        String cleanExistingId = s['id'].toString().replaceAll(RegExp(r'[^0-9]'), '');
                        return cleanExistingId == cleanNewId;
                      });
                      
                      if (isDuplicate) {
                        Navigator.pop(ctx);
                        showAppSnackBar(context, "❌ Error: Student ID $cleanNewId is already in this course!", isError: true);
                        return; 
                      }

                      Navigator.pop(ctx);
                      
                      await FirebaseFirestore.instance.collection('courses').doc(courseId).update({
                        'students_list': FieldValue.arrayUnion([{
                          'name': newName,
                          'id': cleanNewId, 
                          'device_uuid': '',
                          'status': 'absent'
                        }])
                      });
                      
                      if (context.mounted) showAppSnackBar(context, "✅ Student added successfully!", isError: false);
                    }
                  },
                  child: const Text("Add"),
                ),
              ],
            ),
          );
        },
      ),
    //33  
    );
 
  } 
 
}