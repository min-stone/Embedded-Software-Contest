import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:train_system/realtime_arrival_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_validate()) return;
    await _authCall(() async {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text.trim(),
      );
    }, successMsg: '로그인 성공');
  }

  Future<void> _register() async {
    if (!_validate()) return;
    await _authCall(() async {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text.trim(),
      );
    }, successMsg: '회원가입 성공');
  }

  bool _validate() {
    final ok = _formKey.currentState?.validate() ?? false;
    setState(() => _error = ok ? null : '입력을 확인해 주세요.');
    return ok;
  }

  Future<void> _authCall(Future<void> Function() fn, {required String successMsg}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await fn();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const RealtimeArrivalScreen()),
      );
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'invalid-email' => '이메일 형식이 올바르지 않습니다.',
        'email-already-in-use' => '이미 사용 중인 이메일입니다.',
        'user-not-found' || 'wrong-password' => '이메일 또는 비밀번호가 올바르지 않습니다.',
        'weak-password' => '비밀번호는 6자 이상이어야 합니다.',
        'too-many-requests' => '요청이 많습니다. 잠시 후 다시 시도하세요.',
        'network-request-failed' => '네트워크 오류가 발생했습니다.',
        _ => '오류가 발생했습니다. (${e.code})',
      };
      setState(() => _error = msg);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      const msg = '알 수 없는 오류가 발생했습니다.';
      setState(() => _error = msg);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final buttons = Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _signIn,
            child: _loading
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('로그인'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _loading ? null : _register,
            child: const Text('회원가입'),
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: const Text('로그인')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: AutofillGroup(
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: const TextStyle(color: Colors.red)),
                  ),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.username, AutofillHints.email],
                  decoration: const InputDecoration(labelText: '이메일', border: OutlineInputBorder()),
                  validator: (v) {
                    final s = (v ?? '').trim();
                    if (s.isEmpty) return '이메일을 입력하세요.';
                    if (!s.contains('@') || !s.contains('.')) return '올바른 이메일을 입력하세요.';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: '비밀번호', border: OutlineInputBorder()),
                  validator: (v) {
                    final s = (v ?? '').trim();
                    if (s.isEmpty) return '비밀번호를 입력하세요.';
                    if (s.length < 6) return '비밀번호는 6자 이상이어야 합니다.';
                    return null;
                  },
                  onFieldSubmitted: (_) => _loading ? null : _signIn(),
                ),
                const SizedBox(height: 20),
                buttons,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
