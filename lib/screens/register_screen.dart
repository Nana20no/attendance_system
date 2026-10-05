import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart'; // للمصادقة وإنشاء الحساب
import 'package:cloud_firestore/cloud_firestore.dart'; // لحفظ بيانات الطالب
import '../constants/app_constants.dart';
import '../services/device_security_service.dart'; // مكتبة البصمة الأمنية
import '../services/file_parser_service.dart';
import '../mixins/alert_mixin.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> with AlertMixin {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _studentIdController = TextEditingController(); 
  final FirebaseAuth _auth = FirebaseAuth.instance;
  bool _isLoading = false;
  bool _isPasswordVisible = false;
  // =========================================================================
  //  وظيفة: التحقق من البيانات (Validation)
  //  المنطق: قبل أن نرسل أي شيء للسيرفر، نتأكد أن الاسم ثلاثي وأن الإيميل يتبع دومين الجامعة.
  //  للشرح: "أطبق مبدأ (Client-side Validation) لتوفير اتصالات السيرفر وتقليل الأخطاء."
  // =========================================================================
  bool _isFullNameValid(String name) {
    List<String> nameParts = name.trim().split(RegExp(r'\s+'));
    return nameParts.length >= 3;
  }

  bool _isValidEmail(String email) {
    return email.trim().toLowerCase().endsWith(AppConstants.universityEmailDomain);
  }
  // =========================================================================
  //  الدالة: _register (عملية التسجيل الأمنية)
  //  المكتبات: Firebase Auth, Cloud Firestore, DeviceSecurityService
  //  المنطق: 
  // 1. توليد بصمة جهاز فريدة (Device UUID).
  // 2. التحقق من عدم وجود حساب آخر مسجل بنفس البصمة (Hardware Security).
  // 3. التحقق من عدم تكرار رقم القيد (Duplicate ID Error).
  // 4. إنشاء الحساب في Firebase ثم حفظ البيانات في Firestore.
  // =========================================================================
  Future<void> _register() async {
    FocusScope.of(context).unfocus();
    String name = _nameController.text.trim();
    String email = _emailController.text.trim().toLowerCase();
    String password = _passwordController.text.trim();
    String studentId = FileParserService.sanitizeId(_studentIdController.text);
    // التحقق من البيانات الفاضيه
    if (name.isEmpty || email.isEmpty || password.isEmpty || studentId.isEmpty) {
      showAppSnackBar(context, "All required fields must be completed.");
      return;
    }

    if (!_isFullNameValid(name)) {
      showAppSnackBar(context, "Please enter your legal full name (at least three words).");
      return;
    }

    if (!_isValidEmail(email)) {
      showAppSnackBar(context, "Please authenticate using official ${AppConstants.universityEmailDomain} domain.");
      return;
    }

    setState(() => _isLoading = true);

    try {
      // خطوة أمنية جلب بصمة الجهاز الفريدة (Hardware UUID)
      final securityService = DeviceSecurityService();
      String deviceUuid = await securityService.getOrGenerateDeviceUUID();

      //    في طالب آخر يستخدم نفس الهاتف ؟ (Anti-Spoofing)
      var deviceCheck = await FirebaseFirestore.instance
          .collection('users')
          .where('registered_device_uuid', isEqualTo: deviceUuid)
          .get();

      if (deviceCheck.docs.isNotEmpty) {
        throw "Hardware Security: This physical device is bound to an active student account.";
      }

      //  هل رقم القيد مسجل مسبقاً
      var studentCheck = await FirebaseFirestore.instance
          .collection('users')
          .where('student_id', isEqualTo: studentId)
          .get();

      if (studentCheck.docs.isNotEmpty) {
        throw "Enrollment Error: Student ID $studentId is already bound to an account.";
      }
      //  إنشاء الحساب في Firebase Auth
      UserCredential userCredential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);

      String uid = userCredential.user!.uid;
     //  حفظ البيانات في Firestore يتم الربط بين رقم القيد وبصمة الهاتف
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'uid': uid,
        'name': name,
        'email': email,
        'student_id': studentId,
        'role': 'student',
        'registered_device_uuid': deviceUuid, 
        'created_at': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      showAppSnackBar(context, "Secure student account built successfully!", isError: false);
      Navigator.pop(context);

    } on FirebaseAuthException catch (e) {
        //   بدل إظهار كود الخطأ، نظهر رسالة مفهوم
      if (mounted) {
        _auth.signOut();
        String message = "Authentication failed. Please verify your credentials.";
        if (e.code == 'user-not-found' || e.code == 'wrong-password') message = "Invalid email or password.";
        if (e.code == 'email-already-in-use') message = "This email is already registered.";
        showAppSnackBar(context, message);
      }
    } catch (e) {
      if (mounted) {
        _auth.signOut();
        showAppSnackBar(context, "An unexpected system error occurred.");
      }
    
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _studentIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("Secure Account Creation", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: ListView(
        padding: const EdgeInsets.all(32),
        children: [
          const Text("Complete form to bind your device credentials permanently.", style: TextStyle(color: Colors.black54)),
          const SizedBox(height: 32),
          TextField(
            controller: _nameController, 
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: "Full Legal Name", border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _emailController, 
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: "University Email", border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _studentIdController, 
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: "Student ID Number", border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)))
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _passwordController, 
            obscureText: !_isPasswordVisible, 
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: "Password", 
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), 
              suffixIcon: IconButton(
                icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off), 
                onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible)
              )
            )
          ),
          const SizedBox(height: 40),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _isLoading ? null : _register, 
            child: _isLoading 
              ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)) 
              : const Text("Register Credentials", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))
          ),
        ],
      ),
    );
  }
}