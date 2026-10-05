import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';// مكتبة المصادقة (دخول/خروج)
import 'package:cloud_firestore/cloud_firestore.dart'; // قاعدة البيانات
import 'package:shared_preferences/shared_preferences.dart'; // لحفظ جلسة المستخدم محلياً
import '../services/device_security_service.dart'; // خدمتنا الخاصة لـ (بصمة الجهاز)
import '../mixins/alert_mixin.dart';
import 'doctor_dashboard.dart';
import 'student_dashboard.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with AlertMixin {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  bool _isLoading = false;
  bool _isPasswordVisible = false;

  // =========================================================================
  //  الدالة 1: _login (بوابة الدخول الذكية)
  //  المنطق: تأخذ الإيميل والباسورد وتفحص في Firebase هل المستخدم مسجل، ثم تحدد
  // هل هو (دكتور) فينتقل لداشبورد الدكتور، أو (طالب) فينتقل لداشبورد الطالب بعد التأكد من جهازه.
  //  للشرح: "بمجرد دخول الطالب، أقوم بجلب ملفه من Firebase، وأتحقق من دوره (Role) 
  // لأوجهه للشاشة الصحيحة. وفي حالة الطالب، أقوم بتفعيل عملية (Device Verification)."
  // =========================================================================
  Future<void> _login() async {
    FocusScope.of(context).unfocus();
    String email = _emailController.text.trim();
    String password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      showAppSnackBar(context, "Please enter both email and password.");
      return;
    }

    setState(() => _isLoading = true);
    try {
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      
      String uid = userCredential.user!.uid;
      DocumentSnapshot userDoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();

      if (!mounted) return;

      if (userDoc.exists) {
        final data = userDoc.data() as Map<String, dynamic>?;
        String role = data?['role'] ?? 'student';

        if (role == 'doctor') {
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const DoctorDashboard()));
        } else {
          //  هنا يتم التأكد أن الطالب يستخدم هاتفه الخاص
          await _verifyStudentDevice(uid, data);
          if (!mounted) return;
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const StudentDashboard()));
        }
      } else {
        throw "User record not found in system database.";
      }
    } catch (e) {
      if (mounted) {
        _auth.signOut();
        showAppSnackBar(context, e.toString().replaceAll(RegExp(r'\[.*?\]'), '').trim());
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // =========================================================================
  //  الدالة 2: _verifyStudentDevice 
  //  المنطق: تقارن البصمة الحالية للهاتف مع البصمة المسجلة في Firebase لهذا الطالب.
  //  هذه هي (Hardware Binding). أقوم بجلب البصمة (UUID) المخزنة في هاتف الطالب، 
  // وأقارنها بالبصمة المسجلة في حساب الطالب بـ Firebase. لو تطابقوا، يدخل. لو اختلفوا، 
  // يعني الطالب يحاول الدخول من جهاز آخر، فيتم منعه فوراً لحماية النظام من الغش.
  // =========================================================================
  Future<void> _verifyStudentDevice(String uid, Map<String, dynamic>? data) async {
    final securityService = DeviceSecurityService();
    // جلب البصمة الحالية من الهاتف
    String currentDeviceUUID = await securityService.getOrGenerateDeviceUUID();
    // فحص: هل هذا الجهاز مسجل مسبقاً لطالب آخر؟ (لمنع استخدام نفس الهاتف لحسابات متعددة)
    final prefs = await SharedPreferences.getInstance();
    String? lastVerifiedUid = prefs.getString('verified_uid');
    
    if (lastVerifiedUid == uid) return;

    var existingDeviceQuery = await FirebaseFirestore.instance
        .collection('users')
        .where('registered_device_uuid', isEqualTo: currentDeviceUUID)
        .where('uid', isNotEqualTo: uid)
        .get();

    if (existingDeviceQuery.docs.isNotEmpty) {
      throw "Hardware verification error: This device is registered to another student.";
    }

    String registeredUUID = data?['registered_device_uuid'] ?? '';
   // فحص: هل الطالب يحاول الدخول من هاتف جديد؟
    if (registeredUUID != currentDeviceUUID) {
       if (registeredUUID.isNotEmpty) {
          throw "Security restriction: Account is bound to another authorized device.";
       }
       // لو كان الحساب جديد ولم يربط بهاتف، نربطه الآن
       await FirebaseFirestore.instance.collection('users').doc(uid).update({
         'registered_device_uuid': currentDeviceUUID
       });
    }

    await prefs.setString('verified_uid', uid);
  }

  // دالة نسيان كلمة المرور (استخدام Firebase Auth)
  Future<void> _showForgotPasswordDialog() async {
    TextEditingController resetEmailController = TextEditingController(text: _emailController.text);
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.lock_reset_rounded, color: Colors.indigo),
            SizedBox(width: 8),
            Text("Reset Password", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Enter your university email. We will send you a secure link to reset your password.", style: TextStyle(color: Colors.black54, fontSize: 14)),
            const SizedBox(height: 16),
            TextField(
              controller: resetEmailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: "Email Address",
                prefixIcon: const Icon(Icons.email_outlined),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
         ElevatedButton(
  style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
  onPressed: () async {
    String email = resetEmailController.text.trim();
    if (email.isEmpty) return;
    
    Navigator.pop(ctx); 
    try {
      await _auth.sendPasswordResetEmail(email: email);
      if (mounted) showAppSnackBar(context, "✅ Password reset link sent to $email", isError: false);
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        String message = "Authentication failed.";
        if (e.code == 'user-not-found') message = "Email not found.";
        showAppSnackBar(context, message);
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, "Error: Could not send reset link.");
    }
  },
  child: const Text("Send Link"),
),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50, // لون هادئ ونظيف
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                
                // 🎨 تصميم اللوجو الاحترافي الجديد (بدلاً من الرادار العملاق)
                Center(
                  child: Container(
                    height: 110,
                    width: 110,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.indigo.shade400, Colors.indigo.shade900],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(28), // حواف دائرية كأيقونات أبل
                      boxShadow: [
                        BoxShadow(color: Colors.indigo.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 10))
                      ]
                    ),
                    child: const Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(Icons.wifi_tethering_rounded, size: 60, color: Colors.white24), // رادار خفيف بالخلف
                        Icon(Icons.bluetooth_audio_rounded, size: 50, color: Colors.white), // بلوتوث أساسي
                      ],
                    ),
                  ),
                ),
                
                const SizedBox(height: 32),
                
                const Text(
                  "Smart Attendance",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.black87, letterSpacing: 0.5),
                ),
                const SizedBox(height: 6),
                Text(
                  "UOT Secure Authentication Gateway",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                ),
                
                const SizedBox(height: 40),
                
                // حقل الإيميل
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: "University Email",
                    prefixIcon: const Icon(Icons.email_outlined),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
                
                const SizedBox(height: 20),
                
                // حقل الباسورد
                TextField(
                  controller: _passwordController,
                  obscureText: !_isPasswordVisible,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _isLoading ? null : _login(),
                  decoration: InputDecoration(
                    labelText: "Password",
                    prefixIcon: const Icon(Icons.lock_outline),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    suffixIcon: IconButton(
                      icon: Icon(_isPasswordVisible ? Icons.visibility : Icons.visibility_off, color: Colors.grey),
                      onPressed: () => setState(() => _isPasswordVisible = !_isPasswordVisible),
                    ),
                  ),
                ),
                
                // 🔒 زر نسيت كلمة المرور الجديد
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _showForgotPasswordDialog,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text("Forgot Password?", style: TextStyle(color: Colors.indigo.shade600, fontWeight: FontWeight.bold)),
                  ),
                ),
                
                const SizedBox(height: 32),
                
                // زر الدخول
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.indigo,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    elevation: 3,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _isLoading ? null : _login,
                  child: _isLoading 
                    ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)) 
                    : const Text("LOGIN", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                ),
                
                const SizedBox(height: 24),
                
                // زر تسجيل طالب جديد
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("Don't have an account?", style: TextStyle(color: Colors.grey.shade600)),
                    TextButton(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())),
                      child: Text("Register Securely", style: TextStyle(color: Colors.indigo.shade700, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}