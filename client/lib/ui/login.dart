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
      await widget.store.login(user.text.trim(), pass.text,
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
                if (!registering)
                  TextButton(
                    onPressed: () => _recoverDialog(context),
                    child: const Text('¿Olvidaste tu contraseña? Recupérala con tu 2FA',
                        style: TextStyle(color: Pal.muted, fontSize: 12)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _recoverDialog(BuildContext context) {
    final u = TextEditingController(text: user.text);
    final code = TextEditingController();
    final np = TextEditingController();
    var working = false;
    String? err;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Recuperar contraseña', style: TextStyle(fontSize: 17)),
          content: SizedBox(
            width: 340,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                  'Sin emails: usa el código de tu app de autenticación (2FA).',
                  style: TextStyle(fontSize: 12.5, color: Pal.muted)),
              const SizedBox(height: 12),
              TextField(controller: u, decoration: const InputDecoration(labelText: 'Usuario')),
              const SizedBox(height: 8),
              TextField(
                  controller: code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(labelText: 'Código 2FA (6 dígitos)', counterText: '')),
              const SizedBox(height: 8),
              TextField(
                  controller: np,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Contraseña nueva')),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(err!, style: const TextStyle(color: Pal.red, fontSize: 12.5)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: working
                  ? null
                  : () async {
                      setSt(() { working = true; err = null; });
                      try {
                        await widget.store.recover(
                            u.text.trim(), code.text.trim(), np.text);
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setSt(() { working = false; err = e.toString(); });
                      }
                    },
              child: const Text('Restablecer y entrar'),
            ),
          ],
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
