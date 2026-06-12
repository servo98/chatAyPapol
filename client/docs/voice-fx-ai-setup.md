# Cambiador de voz por IA (RVC) — guía de instalación (EXPERIMENTAL)

ChatPapol incluye dos niveles de efectos de voz:

1. **VoiceFX (DSP)** — integrado en la app, latencia ~0 ms, sin instalar nada.
   Cuevas, robots, pitch, etc. Para la mayoría de la gente esto es suficiente.
2. **Conversión de voz por IA (RVC)** — suena como OTRA voz real (clonación de
   timbre). **No va dentro de la app**: corre como programa externo en tu PC y
   ChatPapol lo orquesta. Esta guía cubre ese segundo nivel.

> **Advertencia honesta**: la conversión por IA en tiempo real añade latencia
> notable (decenas a cientos de ms). Con una NVIDIA decente conversas bien;
> en CPU es inservible para hablar. Lee la tabla de hardware antes de empezar.

## ¿Mi hardware sirve?

| Hardware | Backend | Latencia añadida típica | ¿Recomendado? |
|---|---|---|---|
| GPU NVIDIA (GTX 1060+ / RTX) | CUDA | ~90–150 ms | ✅ Sí — la experiencia buena |
| AMD / Intel en **Windows** | DirectML | ~180–250 ms | ⚠️ Usable, latencia notoria (experimental) |
| AMD en **Linux** | ROCm | — | ❌ No — el stack RVC en tiempo real sobre ROCm es inestable hoy |
| Solo CPU (cualquier SO) | CPU | ~200–300 ms | ❌ No — inviable para conversar |

ChatPapol detecta esto solo (busca `nvidia-smi`, etc.) y **oculta la sección de
IA** si tu máquina no llega. Si crees que detectó mal (p. ej. acabas de instalar
drivers), reinicia la app.

## Cómo funciona la tubería

El programa externo convierte tu voz y la "emite" por un micrófono **virtual**;
ChatPapol escucha ese micrófono virtual en lugar del físico:

```
mic físico → VC Client (modelo RVC) → cable de audio virtual → ChatPapol
                                                              (mic = cable virtual)
```

Después, dentro de ChatPapol, tu voz convertida pasa igualmente por la
supresión de ruido y por los efectos VoiceFX si los activas.

## Paso 1 — Instalar w-okada VC Client

1. Descarga el **VC Client** de w-okada: <https://github.com/w-okada/voice-changer>
   (releases precompiladas para Windows; en Linux se ejecuta desde el repo).
2. Elige la edición según tu GPU:
   - NVIDIA → edición **CUDA**.
   - AMD/Intel en Windows → edición **DirectML**.
3. Arranca el cliente una vez a mano para verificar que abre su panel web
   (por defecto en `http://localhost:18888`).

## Paso 2 — Conseguir un modelo RVC

- **No necesitas entrenar nada**: hay miles de modelos RVC prehechos
  (`.pth`/`.onnx`) publicados por la comunidad; descarga uno y cárgalo en el
  VC Client.
- **Licencias y ética**: muchos modelos clonan voces de personas reales
  (cantantes, actores, streamers). Úsalos solo donde su licencia lo permita y
  no suplantes identidades. Si entrenas un modelo propio, necesitas ~10+ min
  de audio limpio de la voz objetivo y una GPU para entrenar (eso sí es lento).
- Guarda la ruta del modelo: la configurarás también en ChatPapol
  (ajuste `ai_vc_model`) para tenerla a mano.

## Paso 3 — Cable de audio virtual

### Windows: VB-Cable

1. Instala **VB-Cable** (donationware): <https://vb-audio.com/Cable/>
   y reinicia.
2. Aparecen dos dispositivos: `CABLE Input` (un altavoz falso) y
   `CABLE Output` (un micrófono falso).
3. En el **VC Client**: entrada = tu micrófono físico, salida =
   **`CABLE Input (VB-Audio Virtual Cable)`**.
4. En **ChatPapol** → Ajustes → Voz → Micrófono: elige
   **`CABLE Output (VB-Audio Virtual Cable)`**.

### Linux: PipeWire / PulseAudio

1. Crea un sink virtual (sobrevive hasta reiniciar; añádelo a tu autostart si
   quieres que sea permanente):

   ```bash
   pactl load-module module-null-sink sink_name=voicefx_ai \
     sink_properties=device.description=VoiceFX-AI
   ```

2. En el **VC Client**: entrada = tu micrófono físico, salida = `VoiceFX-AI`.
3. En **ChatPapol** → Ajustes → Voz → Micrófono: elige
   **`Monitor of VoiceFX-AI`** (el "monitor" del sink es su lado de captura).
4. Para deshacer: `pactl unload-module module-null-sink`.

## Paso 4 — Conectar ChatPapol con el sidecar

En la sección de IA de los ajustes de voz (visible solo si tu hardware da la
talla) configura:

| Ajuste | Qué poner |
|---|---|
| Ejecutable (`ai_vc_exe`) | Ruta al binario del VC Client (p. ej. `C:\vcclient\MMVCServerSIO.exe`) |
| Argumentos (`ai_vc_args`) | Flags extra del servidor, opcional (usa comillas dobles si una ruta tiene espacios) |
| Dispositivo de entrada (`ai_vc_input_device`) | Tu micrófono físico (lo usa el VC Client) |
| Dispositivo de salida (`ai_vc_output_device`) | El cable virtual (`CABLE Input` / `VoiceFX-AI`) |
| Modelo (`ai_vc_model`) | Ruta a tu `.pth`/`.onnx` |

Con eso, ChatPapol puede arrancar/parar el VC Client por ti y mostrar su log.
**ChatPapol no descarga ni incluye modelos ni binarios**: todo lo de arriba lo
instalas tú.

## Problemas comunes

- **Me oigo robótico/entrecortado** → sube el *chunk size* en el VC Client
  (más latencia, menos cortes) o baja la calidad del modelo.
- **Mucho retardo** → confirma que el VC Client usa la GPU (panel del cliente:
  backend CUDA/DirectML, no CPU). En CPU esto no tiene arreglo.
- **ChatPapol no me oye** → el micrófono de ChatPapol debe ser el cable virtual
  (`CABLE Output` / `Monitor of VoiceFX-AI`), no tu micrófono físico.
- **Se oye doble voz** → tu app de chat escucha el mic físico Y el virtual, o el
  VC Client tiene el monitor (passthrough) activado; apaga uno.
- **Quiero volver a mi voz normal** → para el sidecar y vuelve a seleccionar tu
  micrófono físico en ChatPapol.
