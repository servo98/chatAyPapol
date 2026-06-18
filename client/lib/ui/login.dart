import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
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
  final confirmPass = TextEditingController();
  final invite = TextEditingController();
  bool registering = false;
  bool busy = false;
  // labels de campos cuya contraseña está revelada (visibilidad por-campo).
  final _revealed = <String>{};
  String? error;

  Future<void> _submit() async {
    if (registering && pass.text != confirmPass.text) {
      setState(() => error = 'las contraseñas no coinciden');
      return;
    }
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
    // La tarjeta no debe exceder el ancho disponible (móvil/ventana estrecha).
    final cardW = MediaQuery.sizeOf(context).width - 32;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.1,
            colors: [Pal.bg2, Pal.bg0],
          ),
        ),
        child: Center(
          child: Container(
            width: cardW < 400 ? cardW : 400,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Pal.bg1,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Pal.borderDefault),
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
                Center(
                  child: Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      color: Pal.inset,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Pal.borderStrong),
                      boxShadow: Pal.glowGreenSm,
                    ),
                    alignment: Alignment.center,
                    child: Text('❯',
                        style: TextStyle(
                            color: Pal.accent, fontSize: 30, height: 1,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  registering ? 'crea tu cuenta' : 'hola de nuevo',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text('ChatPapol — tu server, tus reglas',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Pal.muted, fontSize: 13)),
                const SizedBox(height: 24),
                _field('USUARIO', user),
                _field('CONTRASEÑA', pass, obscure: true, revealable: true,
                    onSubmit: _submit),
                if (registering)
                  _field('CONFIRMAR CONTRASEÑA', confirmPass,
                      obscure: true, revealable: true, onSubmit: _submit),
                if (registering)
                  _field('CÓDIGO DE INVITACIÓN', invite,
                      hint: 'vacío si eres el primero', onSubmit: _submit),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(error!,
                        style: TextStyle(color: Pal.red, fontSize: 13)),
                  ),
                ElevatedButton(
                  onPressed: busy ? null : _submit,
                  child: busy
                      ? SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Pal.greenInk))
                      : Text(registering ? '❯ registrarme' : '❯ entrar'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => setState(() {
                    registering = !registering;
                    error = null;
                  }),
                  child: Text(
                    registering
                        ? '¿ya tienes cuenta? inicia sesión'
                        : '¿necesitas una cuenta? regístrate',
                    style: TextStyle(color: Pal.link, fontSize: 13),
                  ),
                ),
                if (!registering)
                  TextButton(
                    onPressed: () => _recoverDialog(context),
                    child: Text('¿olvidaste tu contraseña? recupérala con tu 2FA',
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
          title: const Text('recuperar contraseña', style: TextStyle(fontSize: 17)),
          content: SizedBox(
            width: (MediaQuery.sizeOf(ctx).width - 80).clamp(0.0, 340.0),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                  'sin emails: usa el código de tu app de autenticación (2FA).',
                  style: TextStyle(fontSize: 12.5, color: Pal.muted)),
              const SizedBox(height: 12),
              TextField(controller: u, decoration: const InputDecoration(labelText: 'usuario')),
              const SizedBox(height: 8),
              TextField(
                  controller: code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(labelText: 'código 2FA (6 dígitos)', counterText: '')),
              const SizedBox(height: 8),
              TextField(
                  controller: np,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'contraseña nueva')),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(err!, style: TextStyle(color: Pal.red, fontSize: 12.5)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('cancelar')),
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
              child: const Text('restablecer y entrar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl,
      {String hint = '', bool obscure = false, bool revealable = false,
      VoidCallback? onSubmit}) {
    final shown = _revealed.contains(label);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('// $label',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500,
                  color: Pal.muted, letterSpacing: 1.44)),
          const SizedBox(height: 6),
          GlowOnFocus(
            child: TextField(
              controller: ctrl,
              obscureText: obscure && !shown,
              decoration: InputDecoration(
                hintText: hint,
                suffixIcon: revealable
                    ? IconButton(
                        icon: Icon(
                            shown ? LucideIcons.eyeOff : LucideIcons.eye,
                            size: 18, color: Pal.muted),
                        tooltip: shown ? 'ocultar contraseña' : 'mostrar contraseña',
                        onPressed: () => setState(() {
                          if (!_revealed.remove(label)) _revealed.add(label);
                        }),
                      )
                    : null,
              ),
              onSubmitted: (_) => onSubmit?.call(),
            ),
          ),
        ],
      ),
    );
  }
}
