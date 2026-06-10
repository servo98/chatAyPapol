import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../store.dart';
import '../theme.dart';

/// Diálogo de enrolamiento 2FA: muestra el QR (otpauth) para escanear con
/// Google Authenticator/Authy/1Password y pide el primer código para
/// confirmar. Se usa tras el registro y al activar 2FA desde ajustes.
Future<void> showTotpEnroll(BuildContext context, AppStore store,
    {required String uri, required String secret}) {
  final code = TextEditingController();
  var working = false;
  String? err;
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSt) => AlertDialog(
        title: const Text('Protege tu cuenta (2FA)', style: TextStyle(fontSize: 17)),
        content: SizedBox(
          width: 340,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
                'Escanea el QR con tu app de autenticación (Google Authenticator, '
                'Authy, 1Password…). Te pedirá el código solo para cambios '
                'sensibles y para recuperar tu contraseña.',
                style: TextStyle(fontSize: 12.5, color: Pal.muted)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(10)),
              child: QrImageView(data: uri, size: 168),
            ),
            const SizedBox(height: 8),
            // por si no puede escanear: el secreto en texto, tap para copiar
            InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: secret));
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text('Secreto copiado'), duration: Duration(seconds: 1)));
              },
              child: Text('o ingresa el secreto: $secret',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: Pal.faint)),
            ),
            const SizedBox(height: 12),
            TextField(
                controller: code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                    labelText: 'Código de 6 dígitos', counterText: '')),
            if (err != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(err!, style: const TextStyle(color: Pal.red, fontSize: 12.5)),
              ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Después', style: TextStyle(color: Pal.muted))),
          FilledButton(
            onPressed: working
                ? null
                : () async {
                    setSt(() { working = true; err = null; });
                    try {
                      await store.api.post(
                          '/api/auth/totp/confirm', {'code': code.text.trim()});
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      setSt(() { working = false; err = e.toString(); });
                    }
                  },
            child: const Text('Confirmar'),
          ),
        ],
      ),
    ),
  );
}

/// Pide el código 2FA de 6 dígitos. Devuelve null si el usuario cancela.
Future<String?> askTotpCode(BuildContext context, {String? reason}) {
  final code = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Código 2FA', style: TextStyle(fontSize: 17)),
      content: SizedBox(
        width: 280,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(reason ?? 'Confirma con el código de tu app de autenticación.',
              style: const TextStyle(fontSize: 12.5, color: Pal.muted)),
          const SizedBox(height: 12),
          TextField(
            controller: code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            textAlign: TextAlign.center,
            decoration:
                const InputDecoration(labelText: '6 dígitos', counterText: ''),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, code.text.trim()),
            child: const Text('Confirmar')),
      ],
    ),
  );
}
