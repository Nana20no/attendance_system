import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class ReportVaultScreen extends StatefulWidget {
  final String courseId;
  final String courseName;

  const ReportVaultScreen({super.key, required this.courseId, required this.courseName});

  @override
  State<ReportVaultScreen> createState() => _ReportVaultScreenState();
}

class _ReportVaultScreenState extends State<ReportVaultScreen> {
  
  // 📁 دالة جلب التقارير من ذاكرة هاتف الدكتور
  Future<List<File>> fetchLocalReports() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      String safeCourseName = widget.courseName.replaceAll(' ', '_');

      // جلب كل الملفات المحفوظة في التطبيق
      List<FileSystemEntity> allFiles = directory.listSync();

      // فلترة ملفات الإكسيل الخاصة بهذه المادة فقط
      List<File> reportFiles = [];
      for (var entity in allFiles) {
        if (entity is File && entity.path.endsWith('.xlsx') && entity.path.contains(safeCourseName)) {
          reportFiles.add(entity);
        }
      }

      // ترتيب الملفات (الأحدث يظهر أولاً)
      reportFiles.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

      return reportFiles;
    } catch (e) {
      debugPrint("Local Vault Error: $e");
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: Text("Local Vault: ${widget.courseName}"),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder<List<File>>(
        future: fetchLocalReports(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Colors.indigo));
          }

          final files = snapshot.data ?? [];
          if (files.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.folder_off_outlined, size: 80, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  const Text("No reports saved yet.", style: TextStyle(color: Colors.black54, fontSize: 18)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: files.length,
            itemBuilder: (context, index) {
              File file = files[index];
              String fileName = file.path.split('/').last; // استخراج اسم الملف
              String fileSize = (file.lengthSync() / 1024).toStringAsFixed(1); // الحجم بالكيلوبايت

              return Card(
                elevation: 1,
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.green.shade50, shape: BoxShape.circle),
                    child: const Icon(Icons.table_chart_rounded, color: Colors.green),
                  ),
                  title: Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: Text("Size: $fileSize KB", style: TextStyle(color: Colors.grey.shade600)),
                  trailing: IconButton(
                    tooltip: "Share / Export",
                    icon: const Icon(Icons.share_rounded, color: Colors.indigo),
                    onPressed: () async {
                      // عند الضغط على زر المشاركة، تفتح نافذة الإرسال للواتساب أو الإيميل
                      // ignore: deprecated_member_use
                      await Share.shareXFiles([XFile(file.path)], text: 'Archived Report: $fileName');
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}