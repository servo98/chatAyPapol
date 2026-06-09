import 'package:flutter/material.dart';
import '../store.dart';
import '../theme.dart';

class LoginScreen extends StatefulWidget {
  final AppStore store;
  const LoginScreen({super.key, required this.store});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final server = TextEditingController(text: 'http://localhost:3210');
  final user = TextEditingController();
  final pass = TextEditingController();
  final invite = TextEditingController();
  bool registering = false;
  bool busy = false;
  String? error;

  Future<void> _submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.store.login(server.text.trim(), user.text.trim(), pass.text,
          invite: invite.text.trim(), register: registering);
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF13111F), Color(0xFF0D0E13), Color(0xFF101726)],
          ),
        ),
        child: Center(
          child: Container(
            width: 400,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Pal.bg1,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: .5),
                    blurRadius: 40,
                    offset: const Offset(0, 12)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.forum_rounded, size: 52, color: Pal.accent),
                const SizedBox(height: 12),
                Text(
                  registering ? 'Crea tu cuenta' : '¡Hola de nuevo!',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text('ChatPapol — tu server, tus reglas',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Pal.muted, fontSize: 13)),
                const SizedBox(height: 24),
                _field('SERVIDOR', server, hint: 'http://tu-server:3210'),
                _field('USUARIO', user),
                _field('CONTRASEÑA', pass, obscure: true, onSubmit: _submit),
                if (registering)
                  _field('CÓDIGO DE INVITACIÓN', invite,
                      hint: 'vacío si eres el primero', onSubmit: _submit),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(error!,
                        style: const TextStyle(color: Pal.red, fontSize: 13)),
                  ),
                ElevatedButton(
                  onPressed: busy ? null : _submit,
                  child: busy
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(registering ? 'Registrarme' : 'Entrar'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => setState(() {
                    registering = !registering;
                    error = null;
                  }),
                  child: Text(
                    registering
                        ? '¿Ya tienes cuenta? Inicia sesión'
                        : '¿Necesitas una cuenta? Regístrate',
                    style: const TextStyle(color: Pal.link, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl,
      {String hint = '', bool obscure = false, VoidCallback? onSubmit}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  color: Pal.muted, letterSpacing: .5)),
          const SizedBox(height: 6),
          TextField(
            controller: ctrl,
            obscureText: obscure,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (_) => onSubmit?.call(),
          ),
        ],
      ),
    );
  }
}
