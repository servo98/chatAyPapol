# Presets de VoiceFX — manifest JSON editable

Los presets de efectos de voz (Cueva, Robot, Demonio, Hombre → Mujer, …) son
**datos, no código**: viven en `assets/voicefx_presets.json` y se cargan en
runtime con `loadVoiceFxPresetsFromJson()` (`lib/audio/voice_fx_presets.dart`).
Añadir o retocar un preset **no requiere recompilar el cliente**.

La referencia autoritativa de efectos, parámetros y rangos es
[`native/voicefx/CONTRACT.md`](../native/voicefx/CONTRACT.md) (§3 tabla de
parámetros, §4 schema, §5 presets canónicos).

## Dónde está el archivo en una instalación

En desktop, Flutter instala los assets como archivos planos junto al ejecutable:

- **Windows:** `<carpeta de ChatPapol>\data\flutter_assets\assets\voicefx_presets.json`
- **Linux:** `<carpeta de chatpapol>/data/flutter_assets/assets/voicefx_presets.json`

Edita ese JSON, reinicia el cliente (o vuelve a entrar a voz) y listo. En el
repo, el archivo fuente es `client/assets/voicefx_presets.json` (debe estar
registrado en la sección `flutter: → assets:` de `pubspec.yaml`).

## Schema (version 1)

```jsonc
{
  "version": 1,
  "presets": [
    {
      "id": "cueva",            // OBLIGATORIO. Estable, snake_case. Es la clave
                                // de persistencia: no lo cambies después.
      "label": "Cueva",         // Etiqueta humana en español; la UI la muestra tal cual.
      "category": "room",       // "room" | "character" | "gender" → agrupación en la UI.
      "master": {               // OPCIONAL. Etapa final de mezcla.
        "wetMix": 1.0,          //   0.0–1.0: 0 = solo voz limpia, 1 = solo efecto.
        "outGain": 1.0          //   0.0–4.0: ganancia lineal de salida.
      },
      "chain": [                // Orden del array == orden de procesado. Máx 16 nodos.
        {
          "type": "reverb",     // Tipo de efecto (tabla de abajo).
          "bypass": false,      // OPCIONAL, default false.
          "params": {           // Claves de la tabla de abajo. Omitida → default.
            "roomsize": 0.92, "damp": 0.25, "wet": 0.55
          }
        }
      ]
    }
  ]
}
```

> El archivo real es JSON estricto: **sin comentarios**.

### Efectos y parámetros disponibles (v1)

| `type` | params (rango, default) |
|---|---|
| `reverb` | `roomsize` 0–1 (0.5), `damp` 0–1 (0.5), `wet` 0–1 (0.33) |
| `delay` | `timeMs` 1–2000 (350), `feedback` 0–0.95 (0.35), `mix` 0–1 (0.5) |
| `biquad` | `type` 0=LP 1=HP 2=BP 3=NOTCH (0), `freq` 20–20000 Hz (1000), `q` 0.1–10 (0.707) |
| `ringmod` | `freq` 1–2000 Hz (30), `mix` 0–1 (1.0) |
| `distortion` | `drive` 1–50 (8), `mix` 0–1 (1.0) |
| `pitch` | `semitones` −12…+12 (0), `formant` 0.5–2.0 (1.0; <1 voz «grande», >1 «pequeña») |
| `noise` | `level` 0–1 (0.05), `color` 0–1 (0.5; 0=blanco, 1=oscuro) |
| `tremolo` | `rate` 0.1–20 Hz (5), `depth` 0–1 (0.5) |
| `chorus` | `rate` 0.05–5 Hz (0.8), `depth` 0–1 (0.4), `mix` 0–1 (0.5) |

## Añadir un preset nuevo (sin recompilar)

1. Abre `voicefx_presets.json` (ruta de arriba).
2. Copia un preset existente dentro de `"presets"` y cámbiale `id`, `label`,
   `category` y la `chain`. Ejemplo — "estadio" (voz de megafonía lejana):

```json
{
  "id": "estadio",
  "label": "Estadio",
  "category": "room",
  "chain": [
    { "type": "biquad", "params": { "type": 2, "freq": 1800.0, "q": 1.2 } },
    { "type": "distortion", "params": { "drive": 6.0, "mix": 0.5 } },
    { "type": "delay", "params": { "timeMs": 320.0, "feedback": 0.35, "mix": 0.30 } },
    { "type": "reverb", "params": { "roomsize": 0.95, "damp": 0.2, "wet": 0.5 } }
  ]
}
```

3. Guarda y reinicia el cliente. El preset aparece en su categoría.

Reglas de robustez (no puedes "romper" el cliente con el JSON):

- Un `id` ya existente **reemplaza** al preset builtin (así se afinan los de
  fábrica); ids nuevos se añaden al final.
- `type` desconocido → se descarta ese preset entero (con warning en debug).
- Param desconocido → se ignora solo ese param.
- Valores fuera de rango → se clampean al rango de la tabla.
- Más de 16 nodos → los extra se ignoran.
- JSON ilegible/ausente → el cliente usa los presets compilados de fábrica.

Para validar de oído sin entrar a una sala, usa el harness CLI del motor
(WAV mono 48 kHz de entrada → WAV procesado; ver `client/tool/`).

## ¿Y un TIPO de efecto nuevo (p. ej. vocoder, flanger)?

Eso ya no es JSON: los `type` son primitivas DSP implementadas en la librería
nativa (`client/native/voicefx`, C++). Requiere:

1. Implementar el DSP en la lib nativa y **añadir** (nunca renumerar) el valor
   al enum `VfxEffectType` y su bloque de 100 `paramId` en
   `native/voicefx/include/voicefx.h` + CONTRACT.md §3.
2. Espejar el enum en el Dart del engine, añadir las claves/rangos a la tabla
   de params de `voice_fx_presets.dart` y a este doc.
3. Recompilar `voicefx.dll` / `libvoicefx.so` y el cliente.

Los clientes viejos ignoran presets que usen tipos que no conocen
(forward-compat), así que publicar presets nuevos antes de que todos
actualicen es seguro.

Para inspirarse o portar primitivas DSP con licencias permisivas:

- **Faust** (<https://faust.grame.fr>) — lenguaje DSP funcional con cientos de
  efectos en `faustlibraries` (reverbs, phasers, vocoders); compila a C++ que
  se puede adaptar al ABI de `voicefx`.
- **Airwindows** (<https://www.airwindows.com>, GitHub `airwindows/airwindows`)
  — ~400 efectos MIT en C++ sencillo (un archivo por efecto), fáciles de
  destilar a un nodo del chain.
