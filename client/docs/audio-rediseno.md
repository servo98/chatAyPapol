# Rediseño del sistema de audio de ChatPapol

Plan de arquitecto (jun 2026), basado en auditoría multi-agente + hechos verificados en vivo.
Decisiones del dueño tomadas: **48k = simplificar + explorar supresor de ruido propio**;
**EQ = 8 bandas**; **efectos = poda ligera**; **boost de captura = sí**.

## Hechos verificados (no teoría)
- Fork en uso = `ef70bf3` (pubspec.lock). La "regresión 48k" = este repin (metió AGC+gate siempre-on).
- 48k corre por defecto cuando está opt-in ON (session.log v0.2.13: "publicando micro CUSTOM 48k").
- EQ por-usuario SÍ entrega PCM real (eq-probe.txt) → 8 bandas es viable.
- Singleton de DSP colisiona: bands.txt mostró `rate_=16000` en el path 48k (carrera 16k↔48k real).
- `VFX_COMP` (=9) SÍ está implementado (voicefx.h:68) — el "RESERVADO" en voice_fx.dart miente.
- Warning `voicefx.dll no encontrado` = FFI standalone muerto (inocuo). Borrable.

## Causa raíz de "48k falla sin filtros"
`rnnoise_processor.cc::ProcessCustom48` aplica `data[i]*agc_gain_*gate_g` INCONDICIONALMENTE
(:250-255) y el AGC adapta con rnnoise OFF (`agc_adapt = !rnnoise_on_`, :241), con hard-clip a
±32767. Basta tener fullband48k ON para que TODO pase por ese AGC destructivo. Mitigación
inmediata sin build: apagar "Micro fullband 48 kHz" (cae al path 16k que funciona).

## Arquitectura objetivo
- **Dos modos, un motor de DSP de verdad, procesador SEPARADO por ruta** (romper el singleton).
  - **Estándar (default, 16k APM):** AEC on + AGC suave + RNNoise real + VoiceFX. Donde viven ruido/efectos.
  - **Alta calidad (opt-in, 48k, auriculares):** captura limpia, DSP propio mínimo/nulo.
- **El usuario elige intención, el código elige el algoritmo.** Exponer: "Reducir ruido Off/Estándar/Fuerte",
  "Cancelar eco", "Nivelar mi volumen" (AGC), "Volumen de entrada" (boost), "Modo alta calidad".
  Esconder NS/AEC/AGC/RNNoise crudos.

## UX objetivo (tab Voz)
Secciones: **Dispositivos** (mic + salida + "probar altavoces") · **Mi micrófono** (reducir ruido /
eco / nivelar / boost / alta calidad) · **Probar micro** (UN botón: monitor automático + medidor;
sub-toggle "oírme con efectos"; aviso auriculares) · **Volumen de salida**.
"Probar micro" debe funcionar FUERA de un canal y salir por el device SELECCIONADO (hoy: 2 controles
contradictorios, monitor solo dentro de canal y por device default). Monitor = solo Windows (gatear en Linux).

## EQ 8 bandas (por-usuario, clic derecho)
Freqs fijas: 60/120/250/500/1k/2.4k/6k/12k Hz. Banda0=LowShelf, 1-6=Peaking(Q~1.0-1.4), 7=HighShelf.
Rango ±12 dB, step 0.5. Presets: Plano/Voz clara/Cálido/Radio/Aire/Grave.
- Dart: `UserEqSettings` → `List<double> gains` (kEqFreqs constante); JSON `{v:2,g:[...],p}` con
  migración del viejo {b,m,t}. UI: N faders verticales, `_EqCurvePainter` en escala log. Popover ~400px.
  Separar debounce volumen/EQ.
- Nativo (fork): `SetEq(vector<float>)`, `EnsureChainAudioThread` itera kFreqs[8], MethodChannel con lista.

## Decisión 48k: SIMPLIFICAR + explorar supresor propio
1. Inmediato: passthrough bit-exact en ProcessCustom48 si todo OFF; procesador dedicado;
   InitializeCustom48() + reset de gate/agc en Start; AGC opt-in y suave (tope +6/9 dB, soft-knee).
2. Objetivo: 48k = captura limpia; ruido/efectos solo en estándar 16k.
3. Explorar (decisión del dueño): supresor de ruido propio basado en teoría (spectral subtraction /
   RNNoise nativo a 48k). Track de investigación aparte.

## Plan por fases
### Fase A — solo-cliente (Dart, verificable con build, sin fork, sin firma Windows)
1. Borrar FFI muerto (voicefx_bindings + VoicefxNative + processFrame) → mata el warning + ABI mismatch.
2. Quitar "RESERVADO" de `comp` y exponerlo.
3. preset desc/icon desde los datos del preset (fin del desfase).
4. Unificar tablas de params + arreglar _ParamSlider/_fmtParam para biquad 0..6 (evita crash).
5. Separar debounce volumen/EQ en user_audio_popover.
6. UserEqSettings → List<double> + UI 8 faders + curva log + migración JSON (efectivo al llegar Fase B nativa).
7. Reorg UX del tab voz (secciones, lenguaje, mover créditos a About).
8. Snackbars de error de dispositivo + limpiar pref obsoleta.
9. Poda LIGERA de presets (solo rotos/inútiles).
10. Gatear monitor en Linux ("solo Windows").

### Fase B — fork C++ + build/firma Windows + ear-QC (clon en code/flutter-webrtc-fork)
1. Arreglar regresión 48k (passthrough guard + procesador dedicado + init/reset). ← URGENTE
2. EQ 8 bandas nativo (SetEq vector + kFreqs).
3. AGC suave/opt-in.
4. "Probar micro" unificado (rutear track al monitor + device seleccionado).
5. Boost de captura nativo (volumen de entrada).
6. Fallback de dispositivo en el nativo (FindCaptureDevice null → default).
7. 48k = captura limpia.
8. Test de salida (SFX por device).
9. (Investigación) supresor de ruido propio a 48k.

## Quitar / Arreglar (resumen)
QUITAR: FFI standalone, 2/3 exposiciones del monitor, toggle de efectos duplicado, créditos del panel,
comentario muerto de processFrame, presets redundantes (poda ligera).
ARREGLAR: "RESERVADO" de comp, _presetDesc/_presetIcon desfasados, 3 tablas de params divergentes,
doble denoise por defecto, errores de device silenciados, ventana sin post-proceso en join, boost de captura.

## Ojo / limpieza
- 9 clones del fork en ~/.pub-cache; pin actual ef70bf3. Confirmar que Windows compila ESE ref.
- MEMORY mencionaba 94dd0e2 (desfasado vs lock).
