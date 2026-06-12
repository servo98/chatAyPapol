# ChatPapol — Plan de Efectos y Cambiadores de Voz (HANDOFF)

> Estado al pausar: motor de efectos en construcción (workflow ultracode/fable corriendo en background).
> Worktree: `.claude/worktrees/voicefx`, branch `feature/voice-fx` (separado para no chocar con el agente que mete RNNoise).

## Cómo retomar mañana
1. Abrir este worktree (`feature/voice-fx`).
2. Revisar si terminó el workflow del motor: ver archivos generados en `client/native/voicefx/` y `client/lib/audio/`.
   - Si el workflow no terminó/quedó a medias: relanzar con `Workflow({scriptPath: "<.claude/.../workflows/scripts/voicefx-engine-wf_13daa6a9-84e.js>", resumeFromRunId: "wf_13daa6a9-84e"})`.
3. Verificar build Linux del motor: `cd client/native/voicefx && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j`, luego `./build/voicefx_cli`. Y `cd client && flutter analyze`.
4. Pasar el PROMPT DE CLAUDE DESIGN (abajo) → cuando vuelva el diseño, implementar la UI sobre la API del motor.
5. Implementar el Bloque 3 (ambiente de sala sincronizado) — subsistema aparte (backend gateway + cliente audioplayers), NO toca el motor nativo.

## Tareas (tracker)
- [x] #1 Motor de efectos de voz (native lib + FFI + presets + AI manager) — COMPLETO en disco
- [x] #2 Verificar build nativo Linux + dart analyze del motor — VERIFICADO:
      - native: build limpio (libvoicefx.so + voicefx_cli), 16 presets corren y transforman audio (md5 distintos), 9 símbolos FFI casan con el binding Dart.
      - dart: `flutter pub get` + `flutter analyze lib/audio` → **No issues found!** (sin bugs; el único "Float32List" era falso positivo, foundation lo reexporta vía serialization.dart).
      - flutter de Windows desde WSL: `cmd.exe /c '... C:\src\flutter\bin\flutter.bat ...'`. Native build Linux: `cmake -S client/native/voicefx -B build && cmake --build build`.
- [x] #3 Redactar prompt UX para Claude Design — HECHO (ver abajo), pendiente pasarlo
- [x] #4 Subsistema de ambiente de sala sincronizado (gateway, no WebRTC) — IMPLEMENTADO Y COMMITEADO (6a7649f). Ver sección abajo.
- [ ] (futuro) Implementar la UI del motor de efectos cuando vuelva el diseño de Claude Design
- [ ] (diseño) Reemplazar el control TEMP de ambiente en voice_panel.dart (_ambience) por el diseño de Claude Design
- [ ] (merge) Cablear vfx_process en el capture-hook nativo al integrar con el fork RNNoise (ver client/docs/voice-fx-integration.md)

## AMBIENTE DE SALA — IMPLEMENTADO (commit 6a7649f)
Cama de sonido compartida por canal de voz. NO va por WebRTC: clip bundleado +
sincronía por gateway.
- Flujo: cliente envía `AMBIENCE_SET/STOP/PAUSE {channel_id,...}` → server valida
  (estar en el canal + permiso USE_SOUNDBOARD) y hace broadcast `AMBIENCE_STATE
  {channel_id, ambience_id, started_at, paused, paused_at?}` al canal. Cada cliente
  reproduce el clip local en loop y hace seek a la posición derivada de started_at.
- Server (server/src/gateway.ts): `roomAmbience` en memoria por canal, handlers,
  `ambience_states` en el snapshot READY (late joiners sincronizan), y limpieza al
  vaciarse el canal (cleanupAmbience).
- Cliente: `lib/ambience.dart` (AmbienceService: loop, seek-sync, volumen propio
  persistido), `AmbienceState` en models, `ambienceStates`+`onAmbienceChange` en
  store, enganche en voice.dart (join/leave/deafen + setAmbience/stopAmbience/
  toggleAmbiencePause), e init en main.dart.
- Assets: 6 clips loopables en client/assets/ambience/ (rain, ocean, wind, fire,
  cave, scifi) generados por client/scripts/gen_ambience.py + ambience_manifest.json.
  Sustituibles por un pack royalty-free con los mismos nombres (freesound.org CC0).
- UI: control TEMP funcional en voice_panel.dart (botón "Ambiente de sala" → hoja
  con catálogo, pausar/detener, slider de volumen). Reemplazar por Claude Design.
- VERIFICADO: flutter analyze lib = limpio; gateway.ts transpila; clips generados.
  PENDIENTE de prueba en vivo: sincronía real con server+LiveKit corriendo.
- LIMITACIÓN conocida: la sincronía usa el reloj LOCAL como proxy del reloj del
  server (sin estimar offset). Para una cama en loop es suficiente; mejora futura:
  estimar el offset cliente-server con el round-trip de PING/PONG del gateway.

### Cómo probar el ambiente (cuando levantes server + cliente)
1. Server: `cd server && bun install && bun run dev` (+ LiveKit: `bun run livekit`).
2. Cliente: `cd client && flutter run -d windows` (o linux).
3. Entra a un canal de VOZ, pulsa el botón "Ambiente de sala" (icono de olas) en
   la barra de controles → elige un ambiente. Debe sonar en loop para todos los del
   canal. Probar pausar/reanudar, detener, slider de volumen, y que un segundo
   cliente que entra tarde caiga sincronizado.
- [ ] (futuro) Implementar la UI cuando vuelva el diseño

---

## RESUMEN DE LA INVESTIGACIÓN (factibilidad)
Encuadre: tiempo real en llamada, hardware mixto (CPU + NVIDIA + AMD, nada solo-CUDA), Windows y Linux, gratis/open source/local.

3 capas por dificultad:
| Capa | Qué | Factible (RT, CPU, AMD+NVIDIA, Win+Linux) | Riesgo |
|---|---|---|---|
| 1. Efectos DSP | reverb iglesia/cueva/sala, eco, radio, teléfono, megáfono, robot, sci-fi | ✅ fácil, <50ms CPU | 🟢 |
| 2. Pitch+formante (sin IA) | grave/agudo, troll, viejo, ardilla, hombre↔mujer "aceptable" | ✅ ~30-100ms CPU | 🟡 |
| 3. Voice conversion IA (RVC) | hombre↔mujer convincente, voz de personaje específico | ⚠️ ~200-430ms, malo en CPU/AMD-Linux | 🔴 |

Hallazgos clave verificados:
- **DSP**: Faust (compila a C++/permisivo) y Airwindows (MIT, 300+ efectos) — comunidad muy activa. Decidimos escribir el DSP a mano (sin deps de toolchain) para que compile/verifique fácil; Faust/Airwindows quedan como upgrade.
- **Pitch/formante sin IA**: Signalsmith Stretch (MIT, header-only, pitch+formant) es lo mejor por licencia; Rubber Band es GPL/comercial (descartado para binario cerrado); SoundTouch ~100ms sin formantes. hombre↔mujer "divertido" sí, "convincente" no sin IA.
- **IA**: w-okada VC Client (RVC/so-vits-svc/Beatrice) es lo más práctico: CPU + DirectML (AMD/Intel, **solo Windows**) + CUDA + ONNX. Latencia CPU ~200-300ms. Seed-VC descartado (NVIDIA-only, ~430ms, repo archivado nov-2025). Linux+AMD es la celda más débil (sin buen camino RT).
- **Integración**: DSP/pitch dentro del capture-hook nativo (FFI), IA como sidecar + dispositivo de audio virtual (VB-Cable Win / PipeWire-Pulse loopback Linux).

Comunidad para "seguir metiendo efectos": (1) presets como JSON editable sin recompilar — lo principal; (2) Faust/Airwindows para primitivas DSP nuevas; (3) RVC/w-okada + weights.gg/voice-models.com para voces IA; (4) freesound.org para ambientes.

---

## DECISIONES DE ARQUITECTURA
- **El PCM del mic solo es accesible en la capa nativa de libwebrtc** (Dart no lo ve). Por eso el DSP es una **librería nativa C++ (C ABI) + bindings FFI**, no Dart puro.
- **No tocar** `voice.dart`, el plugin flutter_webrtc, ni el capture-hook de RNNoise (los toca el otro agente). Entregamos motor autocontenido + contrato de integración de 2-3 líneas; se cablea al hacer merge. Chain runtime: `mic → RNNoise → VoiceFX → WebRTC encode`.
- Solo se tocan archivos compartidos de forma aditiva: `pubspec.yaml` (dep `ffi` + asset presets) y nuevo dir `client/native/`. Runner CMake de windows/linux: NO editar ahora, solo documentar las líneas a añadir al merge.
- **UI la diseña Claude Design**, luego la implemento yo. El motor expone API limpia (ChangeNotifier).

### Distinción CRÍTICA: "quién oye qué"
- **Efectos que transforman MI voz** (reverb cueva, robot, troll, hombre↔mujer): SÍ van por el pipeline de captura → WebRTC (la sala me oye procesado).
- **Cama de AMBIENTE de sala** (goteo cueva, zumbido sci-fi, lluvia): NO por WebRTC. Clip local/bundle + evento de gateway `room_ambience {soundId, action: play|pause|stop, startedAt(servidor), loop, volume}`; cada cliente reproduce en sincronía con `audioplayers`. Ventajas: cero ancho de banda, calidad perfecta, no pisa RNNoise/voz. Cuidar: sincronía por reloj de servidor + seek al unirse tarde, permisos (perms.dart) sobre quién activa, canal de volumen propio, mandar "ambiente actual" en el estado de sala al hacer join.

---

## QUÉ ESTÁ CONSTRUYENDO EL WORKFLOW (motor, sin UI)
Estructura objetivo:
- `client/native/voicefx/include/voicefx.h` — C ABI: VfxChain opaco, enum de efectos, param ids, vfx_create/destroy/clear/add/set_param/set_bypass/set_master/process. process realtime-safe (sin malloc/locks), mono, frame ~480@48k, in-place.
- `client/native/voicefx/src/*.cpp` — DSP a mano: Reverb (Freeverb/Schroeder), Delay/Eco, Biquad (lp/hp/bp/notch), RingMod (robot), Distorsión, Noise (hiss/cama), Tremolo, Chorus, y Pitch+Formant (overlap-add/phase-vocoder, formante independiente). + `voicefx_cli` (harness WAV para verificar) + `CMakeLists.txt` (libvoicefx.so / voicefx.dll).
- `client/lib/audio/voicefx_bindings.dart` — FFI a la C ABI (buffer nativo reutilizable, carga graceful si no existe la lib).
- `client/lib/audio/voice_fx.dart` — `VoiceFxEngine` (ChangeNotifier, singleton): lista ordenada de nodos, add/remove/reorder/setParam/setBypass/setMaster, enabled, loadPreset, persistencia SharedPreferences (`voicefx_state`). Modelos `VoiceFxNode`, `VoiceFxParam` (metadata para sliders), `VoiceFxPreset` (fromJson/toJson).
- `client/lib/audio/voice_fx_presets.dart` + `client/assets/voicefx_presets.json` — presets data-driven (editables sin recompilar).
- `client/lib/audio/ai_voice_changer.dart` — gestor IA (detección hardware → backend none/cpu/cuda/directml/rocm + latencia estimada + gating, sidecar Process start/stop, config de dispositivos virtuales). NO bundlea modelo.
- `client/docs/voice-fx-integration.md`, `voice-fx-presets.md`, `voice-fx-ai-setup.md`.

Presets a entregar (con params concretos en CONTRACT.md):
- Ambiente-sobre-voz: cueva, iglesia/catedral, sala, eco, radio/walkie, teléfono, megáfono, robot, sci-fi.
- Personajes: troll (pitch -7..-10, formant 0.78, +dist+reverb cueva), demonio (-6, 0.8, dist, reverb), viejo (-1.5, 0.92, tremolo, hi-cut), ardilla (+10, 1.3), niño (+4, 1.2).
- Género: hombre→mujer (+4, formant 1.2), mujer→hombre (-5, formant 0.85).

Efectos primitivos encadenables (9): Reverb, Delay/Eco, Biquad, RingMod, Distorsión, Noise, Tremolo, Pitch+Formant, Chorus.

---

## PROMPT PARA CLAUDE DESIGN (pasar tal cual)

```
# Brief de diseño UX/UI — Sistema de Efectos de Voz para ChatPapol

## Contexto del producto
ChatPapol es un chat de voz de escritorio (tipo Discord ligero), hecho en Flutter.
Su identidad visual es un design system terminal/CLI: fondo casi negro con tinte
verde, tipografía monoespaciada (JetBrains Mono), acento verde neón, bordes hairline
(sin sombras pesadas), textura sutil de grilla de fondo, y un "glow" neón verde en
focus/hover como efecto firma. Animaciones cortas (120-180ms). Todo nuevo debe
sentirse parte de ese mundo, NO un mixer de audio genérico.

### Tokens de diseño (úsalos, no inventes colores)
- Fondos: bg0 #06080A, bg1 #0C1110, bg2 #0A0D0C, bg3 #0F1413 (hover/card),
  bg4 #131918 (seleccionado), inset #070A09.
- Acento: verde neón #39FF14, #2CE60F (dim), tinta sobre verde #04140A.
- Texto: #E9F5EC (fuerte), #97A89E (muted), #66786E (faint), #4D5F56 (placeholder).
- Bordes: #161D1A / #1F2824 / #2A352F.
- Secundarios con moderación: link cyan #22D3EE, magenta #FF2E9A, amber #FFB627,
  rojo #FF4D4D. Monoespaciado en TODO. Glow verde en focus/hover.

### Patrones de UI existentes a reutilizar
- Sliders Material activeColor verde + % a la derecha (icono + slider + valor).
- SwitchListTile denso (activeTrackColor verde) para toggles.
- Selector segmentado tipo pills (fila de iconos, activo con fondo bg3).
- Botones-icono pequeños con tooltip. Cards bg0 redondeadas (6-8px), padding 8-12px.
- Diálogos fondo bg1, borde default, radio 8px. Etiquetas de sección 11px faint
  MAYÚSCULAS con letterspacing. NO hay knob: usa sliders (con divisiones) o pills.

## Qué diseñar: TRES bloques (no deben confundirse: clave "quién oye qué").
Propón dónde vive cada cosa (botón "FX" en barra de voz que abre panel/popover +
pestaña completa en Ajustes para avanzado). Justifica.

### BLOQUE 1 — "Mis efectos de voz" (transforma MI voz; la sala me oye así)
- Master ON/OFF muy visible (kill-switch) + indicador persistente de FX activo.
- Presets de un toque en 3 grupos: Ambiente-sobre-voz (Cueva, Iglesia, Sala, Eco,
  Radio, Teléfono, Megáfono, Robot, Sci-Fi); Personajes (Troll, Demonio, Viejo,
  Ardilla, Niño); Género (Hombre->Mujer, Mujer->Hombre). Marca el activo.
- Editor de cadena (avanzado): pila ordenada de nodos en serie; añadir desde paleta
  (Reverb, Delay/Eco, Filtro lp/hp/bp/notch, Ring-Mod, Distorsión, Ruido, Trémolo,
  Pitch+Formante, Chorus); reordenar (drag/flechas); bypass por nodo; borrar; sliders
  por parámetro (2-4 c/u con rango/unidad); mezcla maestra wet/dry + ganancia salida.
- Probar/monitor: oírme a mí antes que la sala, medidor de nivel mini.
- Guardar mi cadena como preset propio.

### BLOQUE 2 — "Cambiador de voz IA" (experimental, depende del hardware)
Conversión RVC (hombre<->mujer realista / personaje). Pesado, mayor latencia, proceso
externo. Diseña sección marcada como experimental que: detecta capacidad y muestra
estado honesto (backend Ninguno/CPU/NVIDIA/DirectML-AMD-Win/ROCm + latencia estimada +
si es recomendado; si no es viable, deshabilitado con motivo); configura ruta del motor,
modelo, dispositivos de audio virtuales; iniciar/detener + estado + log; aviso de
latencia ("tu voz llega ~250ms después"); onboarding de setup por pasos.

### BLOQUE 3 — "Ambiente de sala" (lo oye TODA la sala; NO es mi voz)
Cama de fondo sincronizada para todos (goteo cueva, zumbido sci-fi, lluvia, taberna).
Independiente de mi voz. Deja claro que lo oye la sala; lista de ambientes (one-tap),
play/pause/stop, loop; canal de volumen propio (separado de voz); muestra quién lo
activó y gateado por permisos; estado "ambiente actual" visible al entrar.

## Objetivos de experiencia
1. Claridad "quién oye qué" (Bloque 1 = mi voz, Bloque 3 = sala).
2. Volver a normal al instante (kill-switch + indicador FX activo).
3. Dos niveles: presets de un toque (casual) + editor de cadena (power user).
4. Diversión: presets de personaje juguetones, no panel técnico.
5. Coherencia total con estética terminal/CLI verde-neón monoespaciada.
6. Extensibilidad visible (presets editables/añadibles; estado vacío elegante).

## Entregables
- Ubicación e IA de navegación (con razonamiento).
- Wireframes/mockups de los 3 bloques (presets + editor de cadena del B1; sección IA
  del B2; control de ambiente del B3) en estética Pal.
- Desglose de componentes reutilizables + estados (normal/hover/focus/activo/
  deshabilitado/error).
- Micro-interacciones. Copys en español. Notas de accesibilidad y feedback (avisos de
  latencia IA, indicador FX activo).

Restricción: sin librerías de UI externas ni colores fuera de tokens. Material 3 +
widgets Flutter custom, monoespaciado, verde neón sobre oscuro. Escritorio (ventana),
Windows y Linux.
```

---

## IDs para resumir el workflow
- Run del motor: `wf_13daa6a9-84e` (task id `wtyi4npv4`).
- Script: `.claude/.../workflows/scripts/voicefx-engine-wf_13daa6a9-84e.js`
