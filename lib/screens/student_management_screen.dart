import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../mixins/alert_mixin.dart';

class StudentManagementScreen extends StatefulWidget {
  const StudentManagementScreen({super.key});

  @override
  State<StudentManagementScreen> createState() => _StudentManagementScreenState();
}

class _StudentManagementScreenState extends State<StudentManagementScreen> with AlertMixin {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String _searchQuery = '';

  // 🔓 دالة فك ارتباط الجهاز بالطالب
  Future<void> _unbindDevice(String uid, String studentName) async {
  bool confirm = await showConfirmationDialog(
    context,
    title: "Confirm Unbind",
    content: "Are you sure you want to unlink the device for $studentName?\n\nThis will allow them to login with a new phone.",
    confirmText: "Yes, Unlink",
  );

  if (!confirm) return;

  try {
    await _firestore.collection('users').doc(uid).update({
      'registered_device_uuid': '',
    });
    if (mounted) showAppSnackBar(context, "✅ Device unlinked successfully for $studentName.", isError: false);
  } catch (e) {
    if (mounted) showAppSnackBar(context, "❌ Failed to unlink device: $e");
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        title: const Text("Device Management", style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // 🔍 شريط البحث
          Container(
            color: Colors.indigo,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: TextField(
              onChanged: (value) => setState(() => _searchQuery = value.toLowerCase()),
              decoration: InputDecoration(
                hintText: "Search by Name or Student ID...",
                prefixIcon: const Icon(Icons.search),
                fillColor: Colors.white,
                filled: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          
          // 📋 قائمة الطلاب
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _firestore.collection('users').where('role', isEqualTo: 'student').snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return const Center(child: Text("Error loading students."));
                }

                var docs = snapshot.data?.docs ?? [];
                
                // تطبيق فلتر البحث
                if (_searchQuery.isNotEmpty) {
                  docs = docs.where((doc) {
                    var data = doc.data() as Map<String, dynamic>;
                    String name = (data['name'] ?? '').toString().toLowerCase();
                    String id = (data['student_id'] ?? '').toString().toLowerCase();
                    return name.contains(_searchQuery) || id.contains(_searchQuery);
                  }).toList();
                }

                if (docs.isEmpty) {
                  return const Center(child: Text("No students found."));
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    var data = docs[index].data() as Map<String, dynamic>;
                    String uid = docs[index].id;
                    String deviceId = data['registered_device_uuid'] ?? '';
                    bool isBound = deviceId.isNotEmpty;

                    return Card(
                      elevation: 1,
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isBound ? Colors.green.shade100 : Colors.orange.shade100,
                          child: Icon(
                            isBound ? Icons.phonelink_lock : Icons.phonelink_setup,
                            color: isBound ? Colors.green.shade700 : Colors.orange.shade700,
                          ),
                        ),
                        title: Text(data['name'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text("ID: ${data['student_id']}\nStatus: ${isBound ? 'Device Locked' : 'Ready for New Device'}"),
                        isThreeLine: true,
                        trailing: isBound
                            ? IconButton(
                                tooltip: "Unbind Device",
                                icon: const Icon(Icons.phonelink_erase, color: Colors.redAccent),
                                onPressed: () => _unbindDevice(uid, data['name']),
                              )
                            : const Icon(Icons.check_circle, color: Colors.grey),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}