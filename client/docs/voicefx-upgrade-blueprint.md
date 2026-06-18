# Blueprint: mejora masiva de efectos de voz (voicefx) — nivel Voicemod

> Generado por orquestación multi-agente (ultracode). Tesis: la brecha con Voicemod es **mastering + anti-aliasing + pitch más limpio**, NO IA. Motor embebido, realtime, mono 16 kHz.


## Visión
El motor voicefx YA tiene los huesos correctos (cadena serie lock-free, 9 efectos realtime-safe, suavizado por bloque, undenorm/FTZ, y un phase-vocoder formant-aware vía cepstrum — exactamente el algoritmo que evita el efecto "chipmunk"). La brecha con Voicemod NO es un efecto exótico ni IA: es (a) MASTERING de la cadena (gate + compresor + EQ peaking/shelf + limitador real, hoy inexistentes — solo hay un softClamp final), (b) ANTI-ALIASING en las no linealidades (distortion y ringmod a 16k pliegan armónicos >8kHz justo dentro de la banda de voz: ese es el sonido "barato"), (c) un PITCH más limpio (phase-locking + protección de transitorios, sin añadir FFTs), y (d) primitivas baratas que faltan (bitcrush, vibrato, flanger/comb, EQ peaking/shelf, frequency shifter) más reutilizar el PV existente para autotune y un sub-octave layer. La restricción real es MONO 16k (banda 0 del APM): techo ~8kHz, sin "aire". El mayor ROI estructural es recuperar fullband (correr voicefx sobre el recombinado a 48k en vez de banda 0), pero TODO lo de abajo cabe barato en 16k mono sin mallocs/locks. Plan: primero mastering + anti-alias (sube TODOS los presets de golpe), luego PV mejorado (personajes creíbles), luego nuevos efectos (variedad), y reescribir el catálogo de presets aplicando el orden canónico de cadena con makeup gain igualado.


## Plan de pitch/formantes
MANTENER el phase-vocoder formant-aware actual (STFT + separación fuente/filtro por cepstrum) — es el mejor compromiso calidad/CPU para mono 16k realtime y ya desacopla pitch de formantes (lo que evita el chipmunk). NO migrar a PSOLA (su pitch-tracking por frame es frágil con susurro/ruido en el hilo de audio) ni a WORLD/cross-synthesis (calidad de estudio pero no realtime de baja latencia). El plan es SUBIRLE la calidad al PV existente con 3 mejoras O(bins) sin FFTs extra: (1) identity/peak phase-locking — detectar picos espectrales y hacer que cada bin herede el avance de fase de su pico local; mata la 'phasiness' (voz acuosa/lejana) y es el salto de calidad #1 casi gratis; (2) detección de transitorios por flujo espectral + phase-reset en onsets — devuelve nitidez a consonantes/plosivas que hoy se emborronan; (3) manejo de zona sorda (V/UV por energía-alta/total) randomizando la fase de síntesis para que las eses/efes no suenen a silbido metálico. Afinar para 16k: lifter cut entre sr/400 y sr/300 (~40-53 bins) para capturar ~4 formantes sin morder armónicos; rampar formantRatio ~20-50 ms para evitar morphing chirriante; LP suave (~6kHz) tras pitch-ups grandes para domar el aliasing chillón; aceptar techo útil de pitch-up ~+9/+10 st en 16k (no hay agudos que subir). Reusar este mismo front-end (FFT, magnitudes, trueBin, envolvente cepstral ya calculados por frame) para AUTOTUNE (cuantizar f0 al ratio) y SUB-OCTAVE (segundo recolor a -12st) sin pagar otra FFT — esa reutilización es la vía más barata para los efectos 'caros'. Plan B si algún día el PV se queda corto: Signalsmith Stretch (MIT, header-only, realtime, formant-aware) o Rubber Band detrás de la misma interfaz Effect (pitch.hpp ya lo anticipa).


## Mejoras de motor


### Compresor + Noise Gate (VFX_COMP, type 9)  ·  impacto=alto  ·  esfuerzo=~1 día. Un solo nodo, sin buffers grandes, patrón biquad ya conocido.
- **Qué:** Nodo combinado: detector de envolvente RMS de 1 polo + gate (atenúa bajo umbral, evita amplificar hiss) y compresor (ratio/attack/release/makeup) tras él. Sin FFT, O(n) por muestra, estado fijo pre-alocado en prepare(). Va a effects.hpp (clase CompGate : Effect), effects.cpp (impl + kParamTable + createEffect), voicefx.h (enum + bloque 1000..1099). Params: VFX_P_COMP_GATE_THRESH=1000 (-80..0 dB, def -45), VFX_P_COMP_GATE_RELEASE=1001 (10..300 ms, def 120), VFX_P_COMP_RATIO=1002 (1..20, def 3), VFX_P_COMP_THRESH=1003 (-40..0 dB, def -18), VFX_P_COMP_ATTACK=1004 (1..50 ms, def 10), VFX_P_COMP_RELEASE=1005 (20..300 ms, def 100), VFX_P_COMP_MAKEUP=1006 (0..24 dB, def 0).
- **Por qué:** Es el upgrade de MAYOR impacto/menor esfuerzo: el secreto de que Voicemod suene 'producido' no es un efecto, es dinámica controlada. El gate impide que cualquier preset con drive amplifique el ruido del micro; el compresor 'acerca' la voz y controla picos tras distorsión. Sube la calidad PERCIBIDA de TODOS los presets a la vez.
- **Params nuevos:** VFX_P_COMP_GATE_THRESH=1000, GATE_RELEASE=1001, RATIO=1002, COMP_THRESH=1003, ATTACK=1004, RELEASE=1005, MAKEUP=1006

### Limitador brickwall real en el master (modificar voicefx.cpp)  ·  impacto=alto  ·  esfuerzo=~0.5 día. Modifica solo el master, no añade nodo ni rompe ABI.
- **Qué:** Reemplazar/anteceder el softClamp(tanh) final por un limitador con lookahead corto (16-32 muestras = 1-2 ms a 16k, ringbuffer pequeño pre-alocado): detector de pico + ganancia suavizada que baja ANTES de tocar el techo (-1 dBFS ≈ 0.89 lineal), release 50-100 ms. Dejar el softClamp como red dura DESPUÉS del limitador. Toca solo voicefx.cpp (master stage, ~líneas 58-65) y opcionalmente expone techo vía vfx_set_master si se quiere (no obligatorio).
- **Por qué:** Hoy el master termina en softClamp que distorsiona los picos (eses, colas de reverb/delay, drive alto). Un limitador transparente evita que cualquier preset truene aunque subas outGain para igualar loudness. Cierra la regla 'ninguna voz revienta'.
- **Params nuevos:** Ninguno obligatorio (techo fijo -1 dBFS). Opcional VFX_P en master.

### Anti-aliasing en VFX_DISTORTION y VFX_RINGMOD (modificar effects.cpp)  ·  impacto=alto  ·  esfuerzo=~1 día (ADAA es la vía más barata). No rompe ABI.
- **Qué:** Distortion: aplicar 2x oversampling SOLO dentro del waveshaper (upsample lineal, tanh, LP suave ~7kHz, downsample) o ADAA de 1er orden (antiderivada log(cosh), casi gratis, 1 muestra de memoria). Ringmod: band-limitar — clamp de freq efectiva y un LP suave (~6-7kHz) tras la multiplicación para no plegar la banda lateral superior. Toca effects.cpp (process de Distortion ~323-353 y Ringmod ~288-321). Sin params nuevos (comportamiento interno).
- **Por qué:** Error #1 que delata 'barato' a 16k: tanh(in*drive) e in*seno generan armónicos sobre 8kHz que se PLIEGAN como tonos inarmónicos justo en la voz → áspero/avispero. Es lo que más diferencia megáfono/demonio/robot de la versión pro. Máxima relación calidad/esfuerzo en los efectos existentes.
- **Params nuevos:** Ninguno (interno).

### Pitch: identity phase-locking + protección de transitorios (modificar pitch.cpp)  ·  impacto=alto  ·  esfuerzo=~2 días (cuidado con el tuning del detector). No rompe ABI ni params.
- **Qué:** En processFrame(): (1) detectar picos espectrales locales (mag[k]>mag[k±1,k±2]) y hacer que cada bin no-pico herede el avance de fase de su pico ('region of influence' / identity phase-locking de Laroche-Dolson); (2) detector de flujo espectral barato (sum max(0,mag-magPrev), umbral adaptativo ~1.5-2x media) y en onsets resetear sumPhase_ = fase de análisis; (3) manejo unvoiced: métrica energía-alta/total, en zonas sordas randomizar fase de síntesis para no convertir las eses en silbido metálico. Todo O(bins) reusando magnitudes ya calculadas, CERO FFTs extra. Toca solo pitch.cpp.
- **Por qué:** El PV actual tiene 'phasiness' (voz acuosa/lejana/robótica) y emborrona consonantes en shifts grandes (-8 troll, +10 ardilla). Phase-locking es EL upgrade audible #1 del shifter y acerca a calidad comercial casi gratis; la protección de transitorios devuelve nitidez/inteligibilidad. Sin esto los personajes con pitch fuerte nunca sonarán 'Voicemod'.
- **Params nuevos:** Ninguno (mejora interna del nodo pitch existente).

### EQ peaking + shelf (extender VFX_BIQUAD, no nuevo tipo)  ·  impacto=alto  ·  esfuerzo=~0.5 día. Compatible (solo añade modos + 1 param).
- **Qué:** Añadir 3 modos al VFX_P_BIQUAD_TYPE existente: 4=PEAKING, 5=LOWSHELF, 6=HIGHSHELF, y un nuevo param VFX_P_BIQUAD_GAIN_DB=303 (-15..+15 dB, def 0) usado solo por esos modos. Solo más casos en computeCoeffs() (RBJ cookbook) en effects.cpp ~236-266. Subir el rango de TYPE en _kParamRanges (presets.dart) a (0,6) y añadir 'gainDb'.
- **Por qué:** Hoy solo hay LP/HP/BP/notch: imposible dar presencia (+4dB @3kHz), quitar boxiness (-3dB @300Hz) o calidez (low-shelf). El EQ paramétrico es el 'pegamento' que hace que un preset suene pro en vez de casero, y permite el pre-énfasis/post-shaping correcto en la cadena. Trivial reusando el biquad RBJ.
- **Params nuevos:** VFX_P_BIQUAD_GAIN_DB=303; nuevos TYPE 4=PEAK,5=LOWSHELF,6=HIGHSHELF

### Bitcrusher / decimator (VFX_BITCRUSH, type 10)  ·  impacto=medio  ·  esfuerzo=~0.5 día. Nodo sin estado de buffer.
- **Qué:** Cuantización de bits (round a 2^bits niveles) + sample&hold (downsample por factor entero) + mix. Cero buffers, un contador de hold por muestra. effects.hpp/effects.cpp/voicefx.h, bloque 1100..1199. Params: VFX_P_CRUSH_BITS=1100 (1..16, def 8), VFX_P_CRUSH_DOWNSAMPLE=1101 (1..32, def 1), VFX_P_CRUSH_MIX=1102 (0..1, def 1).
- **Por qué:** Es la pieza que falta para el carácter 'máquina/8-bit/transmisión digital corrupta'. Convierte el robot de 'temblor' a 'Dalek auténtico' y habilita una familia entera de voces gamer/glitch. Baratísimo y de alto 'wow'.
- **Params nuevos:** VFX_P_CRUSH_BITS=1100, VFX_P_CRUSH_DOWNSAMPLE=1101, VFX_P_CRUSH_MIX=1102

### Vibrato + Flanger (VFX_VIBRATO=type 11, VFX_FLANGER=type 12)  ·  impacto=medio  ·  esfuerzo=~1 día los dos juntos (derivados del chorus).
- **Qué:** Vibrato: delay corto modulado por LFO sin mezcla dry (ondulación de PITCH, distinto del tremolo que es amplitud). Flanger: comb corto (0.5-7ms) + LFO + feedback (el chorus actual sin feedback ni dry). Ambos reusan casi 1:1 el código de Chorus existente. Bloques 1200.. y 1300... Params vibrato: RATE=1200 (0.1..12 Hz, def 5.5), DEPTH_CENTS=1201 (0..50, def 20). Flanger: RATE=1300 (0.05..2, def 0.4), DEPTH=1301 (0..1, def 0.6), FEEDBACK=1302 (0..0.9, def 0.6), MIX=1303 (0..1, def 0.5).
- **Por qué:** Vibrato da el temblor REAL de voz anciana/nerviosa que el tremolo solo no logra (hoy 'viejo' suena plano). Flanger da el robot resonante/jet-swoosh psicodélico. Ambos casi gratis reusando Chorus.
- **Params nuevos:** VIBRATO_RATE=1200, VIBRATO_DEPTH_CENTS=1201; FLANGER_RATE=1300, FLANGER_DEPTH=1301, FLANGER_FEEDBACK=1302, FLANGER_MIX=1303

### Autotune / hard-tune (reusar el PV existente)  ·  impacto=medio  ·  esfuerzo=~1.5 días (la f0 robusta es lo delicado). Añade params al pitch, no rompe ABI.
- **Qué:** Dentro del nodo pitch (o nodo hermano que comparte front-end): estimar f0 del trueBin_ ya calculado (pico de baja frecuencia / cepstrum), cuantizar a la nota más cercana de una escala y forzar dinámicamente el ratio del shifter; retune 0 = efecto Cher/T-Pain duro. NO añade FFT. Params nuevos en el bloque pitch: VFX_P_PITCH_AUTOTUNE=602 (0=off,1=on), VFX_P_PITCH_SCALE=603 (0=cromática,1=mayor,2=menor), VFX_P_PITCH_RETUNE_MS=604 (0..200, def 0).
- **Por qué:** Autotune es el efecto 'moderno' que más se nota que falta (trap/hyperpop/Daft Punk). Como reusa el front-end del PV ya pagado, es de los mejores ROI tras el phase-locking. Habilita presets cantados.
- **Params nuevos:** VFX_P_PITCH_AUTOTUNE=602, VFX_P_PITCH_SCALE=603, VFX_P_PITCH_RETUNE_MS=604

### Sub-octave layer (rama paralela ligera en el orquestador)  ·  impacto=medio  ·  esfuerzo=~1-2 días (variante intra-pitch más barata que rama paralela real).
- **Qué:** Soporte en voicefx.cpp para UNA rama paralela: mezclar la señal con una copia desplazada -12 st (segundo pitch) a -6/-9 dB y sumarla bajo el seco. Hoy la cadena es 100% serie; esto requiere que el orquestador permita un nodo 'mix-in'. Alternativa más barata sin tocar arquitectura: añadir al nodo pitch un param VFX_P_PITCH_SUBOCTAVE=605 (0..1 mezcla, def 0) que internamente genera y suma una copia a -12st (segundo recolor de la misma FFT, casi gratis).
- **Por qué:** El 'wall of voice' de demonio/monstruo/coro de Voicemod viene de APILAR voces (la cadena serie no puede). Un sub-octave mezclado al 30-40% da el growl de monstruo más convincente que existe. La variante intra-nodo evita rehacer la arquitectura serie.
- **Params nuevos:** VFX_P_PITCH_SUBOCTAVE=605 (0..1)

### Frequency shifter por Hilbert (VFX_FREQSHIFT, type 13)  ·  impacto=bajo  ·  esfuerzo=~1.5 días (los all-pass de cuadratura requieren cuidado). Nodo nuevo.
- **Qué:** Desplaza TODAS las frecuencias por un offset FIJO en Hz (rompe armonicidad → metálico/alien que el ringmod no logra). All-pass IIR pareados (cuadratura) + oscilador sin/cos. Más barato que el PV. Bloque 1400... Params: VFX_P_FREQSHIFT_HZ=1400 (-1000..+1000, def 120), VFX_P_FREQSHIFT_MIX=1401 (0..1, def 0.5).
- **Por qué:** Da el inarmónico 'shimmering' de nave/alien que ni el ringmod ni el pitch logran; offsets de 1-5 Hz dan phasing fantasma. Completa la familia sci-fi. Coste medio pero menor que un FFT.
- **Params nuevos:** VFX_P_FREQSHIFT_HZ=1400, VFX_P_FREQSHIFT_MIX=1401

### Recuperar ancho de banda fullband (cambio estructural en rnnoise_processor.cc)  ·  impacto=alto  ·  esfuerzo=~3-5 días, alto riesgo (toca el pipeline del APM, revalidar latencia/CPU). Hacerlo DESPUÉS de exprimir todo lo barato en 16k.
- **Qué:** Hoy voicefx corre sobre la BANDA 0 del APM (16k, techo 8kHz, bandas altas a cero). Opción: correr voicefx sobre el fullband recombinado a 48k (o un módulo aparte post-APM) para tener aire >8kHz. Toca rnnoise_processor.cc (~202-244, 307) — es el cambio más invasivo.
- **Por qué:** Es la limitación #1 para 'sonar Voicemod': la voz carece de aire/sibilancia/brillo de mujer-niño. Recuperar 8-16kHz haría que pitch-up, formant-up y agudos suenen MUCHO mejor en toda la biblioteca.
- **Params nuevos:** Ninguno (cambio de pipeline).

## Catálogo de presets


**Demonio del Abismo** _(character)_  
`comp(gateThresh -45, gateRel 120, ratio 4, compThresh -18, attack 15, release 120, makeup 3) → biquad(type HP, freq 100, q 0.707) → pitch(semitones -6, formant 0.80, subOctave 0.35) → distortion(drive 9, mix 0.50)[oversampled] → biquad(type PEAK, freq 2800, q 1.0, gainDb +4) → reverb(roomsize 0.55, damp 0.50, wet 0.15) → master(wetMix 1.0, outGain 1.0)`  
Demonio con cuerpo y coro infernal: pitch+formant abajo, sub-octave para el growl, gate para no amplificar hiss, distorsión sin aliasing, presencia a 2.8k y reverb corto para no ahogar.

**Señor Oscuro (más bestia)** _(character)_  
`comp(gateThresh -42, ratio 5, compThresh -16, makeup 4) → biquad(type HP, freq 90) → pitch(semitones -8, formant 0.77, subOctave 0.45) → distortion(drive 11, mix 0.55)[oversampled] → biquad(type LOWSHELF, freq 150, gainDb +3) → reverb(roomsize 0.60, damp 0.45, wet 0.18) → master(outGain 0.95)`  
Versión más extrema del demonio, capas a -8 + sub-octave imitan el apilado de Voicemod 'The Dark Lord'. Low-shelf da pecho.

**Monstruo / Troll / Ogro** _(character)_  
`comp(gateThresh -45, ratio 3, compThresh -18) → biquad(type HP, freq 95) → pitch(semitones -8, formant 0.78, subOctave 0.30) → distortion(drive 6, mix 0.35)[oversampled] → reverb(roomsize 0.55, damp 0.50, wet 0.18) → master(outGain 1.0)`  
Más grave y formant-down que el demonio, distorsión SUAVE (enriquece sin decimar); el cuerpo viene del formant bajo y el sub-octave, no de saturar.

**Gigante Colosal** _(character)_  
`comp(gateThresh -45, ratio 4, compThresh -16, makeup 3) → pitch(semitones -9, formant 0.72, subOctave 0.40) → biquad(type LOWSHELF, freq 120, gainDb +4) → biquad(type LP, freq 6500, q 0.7) → reverb(roomsize 0.70, damp 0.55, wet 0.22) → master(outGain 0.95)`  
Tracto enorme (formant 0.72) + sub-octave + low-shelf de graves + reverb amplio = escala descomunal. El LP quita brillo fino que delataría el truco.

**Robot Dalek** _(character)_  
`ringmod(freq 30, mix 0.85)[band-limited] → bitcrush(bits 6, downsample 3, mix 0.7) → distortion(drive 6, mix 0.5)[oversampled] → biquad(type BP, freq 1500, q 2.0) → delay(timeMs 45, feedback 0.35, mix 0.25) → master(outGain 1.0)`  
El canon: ringmod bajo metálico + bitcrush (la pieza nueva clave para 'máquina') + band-pass de altavoz + slap corto. Sin el bitcrush solo tiembla; con él suena a transmisión robótica.

**Cyborg / IA** _(character)_  
`comp(gateThresh -45, ratio 3) → ringmod(freq 200, mix 0.25)[band-limited] → flanger(rate 0.3, depth 0.5, feedback 0.6, mix 0.4) → bitcrush(bits 10, downsample 1, mix 0.4) → biquad(type PEAK, freq 3000, q 1.0, gainDb +3) → master(outGain 1.0)`  
Robot sutil y 'tecnológico': ringmod alto leve + flanger resonante + crush ligero. Más 'asistente de IA' que Dalek crudo.

**Alien Shimmering** _(character)_  
`comp(gateThresh -45, ratio 3) → pitch(semitones +3, formant 1.10) → freqshift(hz +120, mix 0.6) → ringmod(freq 250, mix 0.20)[band-limited] → chorus(rate 0.6, depth 0.7, mix 0.5) → reverb(roomsize 0.50, damp 0.50, wet 0.25) → master(outGain 1.0)`  
El frequency shifter da el inarmónico que el ringmod solo no logra; chorus para shimmer etéreo en mono. Pitch leve arriba deshumaniza.

**Alien Grave / Xenomorfo** _(character)_  
`comp(gateThresh -45, ratio 4, compThresh -16) → pitch(semitones -4, formant 0.85) → freqshift(hz -80, mix 0.5) → ringmod(freq 180, mix 0.30)[band-limited] → distortion(drive 4, mix 0.3)[oversampled] → reverb(roomsize 0.55, wet 0.22) → master(outGain 0.97)`  
Variante grave y amenazante: shift negativo + ringmod medio + grit leve. Criatura de otro mundo, no caricatura.

**Chica (Hombre→Mujer creíble)** _(gender)_  
`comp(gateThresh -48, ratio 3, compThresh -18, makeup 2) → biquad(type HP, freq 90) → pitch(semitones +5, formant 1.20)[phase-locked] → biquad(type PEAK, freq 3500, q 1.0, gainDb +3) → reverb(roomsize 0.20, wet 0.10) → master(outGain 1.0)`  
Clave: formant (1.20) sube MENOS que el ratio de pitch para evitar chipmunk; phase-locking limpia consonantes; peak a 3.5k da aire/presencia femenina. No pasar de +6 a 16k.

**Niño Travieso** _(gender)_  
`comp(gateThresh -48, ratio 3) → biquad(type HP, freq 180) → pitch(semitones +5, formant 1.22)[phase-locked] → biquad(type PEAK, freq 4000, q 1.2, gainDb +2) → master(outGain 1.0)`  
Formant alto = tracto pequeño; recortar sub-180Hz evita que suene a 'cinta acelerada'. Más infantil que la chica, sin reverb.

**Ardilla / Chipmunk** _(character)_  
`comp(gateThresh -48, ratio 3) → pitch(semitones +7, formant 1.30)[phase-locked] → biquad(type LP, freq 6500, q 0.7) → master(outGain 0.95)`  
Chipmunk clásico = +7 st + formant alto (munchkin). El LP suave doma el aliasing chillón del pitch-up grande en 16k.

**Helio / Munchkin** _(character)_  
`comp(gateThresh -48, ratio 3) → pitch(semitones +10, formant 1.40)[phase-locked] → biquad(type LP, freq 6000, q 0.7) → master(outGain 0.92)`  
Techo práctico en 16k (+10/+12 ya no tiene agudos que subir). LP obligatorio para quitar el chillido aliaseado. outGain bajo porque sube percepción.

**Hombre Profundo (Mujer→Hombre)** _(gender)_  
`comp(gateThresh -45, ratio 3, compThresh -18, makeup 2) → pitch(semitones -5, formant 0.85)[phase-locked] → biquad(type LOWSHELF, freq 180, gainDb +2) → distortion(drive 2, mix 0.25)[oversampled] → master(outGain 1.0)`  
-5 st + formant bajo (tracto grande); el drive muy leve añade presencia para que no suene 'sordo/hueco'. Si suena embarrado, subir formant a 0.88.

**Narrador de Cine (trailer)** _(character)_  
`comp(gateThresh -42, ratio 6, compThresh -20, attack 8, release 110, makeup 4) → pitch(semitones -2, formant 0.90)[phase-locked] → biquad(type LOWSHELF, freq 110, gainDb +4) → biquad(type PEAK, freq 2500, q 1.0, gainDb +3) → biquad(type LP, freq 7000, q 0.7) → distortion(drive 2, mix 0.25)[oversampled] → reverb(roomsize 0.30, damp 0.6, wet 0.12) → master(outGain 1.0)`  
'In a world...': pitch -2 + formant 0.90 da pecho sin sonar a monstruo; el COMPRESOR fuerte (ahora disponible) + low-shelf de graves + presencia es lo que faltaba para el sonido de tráiler. Reverb mínimo para tamaño.

**Anciano Tembloroso** _(character)_  
`comp(gateThresh -45, ratio 2) → pitch(semitones -1.5, formant 0.92)[phase-locked] → vibrato(rate 5.5, depthCents 22) → tremolo(rate 6.5, depth 0.32) → biquad(type LP, freq 4000, q 0.707) → biquad(type PEAK, freq 300, q 1.0, gainDb -3) → master(outGain 1.0)`  
El VIBRATO (ondulación de pitch, nuevo) + tremolo (volumen) juntos dan el temblor realista que hoy falta; LP quita brillo de oído/voz envejecida; el peak -3 a 300Hz quita boxiness.

**Fantasma / Espectro** _(room)_  
`comp(gateThresh -50, ratio 2) → pitch(semitones -2, formant 0.95) → vibrato(rate 4, depthCents 15) → delay(timeMs 300, feedback 0.40, mix 0.40) → reverb(roomsize 0.90, damp 0.30, wet 0.55) → master(outGain 0.95)`  
Reverb largo (room alto/damp bajo) + delay con feedback medio = 'susurro por un pasillo'. Vibrato leve para inquietud etérea.

**Susurro Siniestro** _(character)_  
`comp(gateThresh -52, ratio 2.5, compThresh -22, makeup 3) → pitch(semitones -3, formant 0.88) → biquad(type HP, freq 200) → biquad(type PEAK, freq 4500, q 2.0, gainDb +4) → noise(level 0.015, color 0.3) → delay(timeMs 220, feedback 0.30, mix 0.25) → reverb(roomsize 0.70, damp 0.40, wet 0.30) → master(outGain 1.0)`  
Voz cercana y amenazante: el compresor con makeup 'pega' el susurro al oído, el peak agudo realza el aire de aliento, pizca de ruido + delay/reverb medios dan presencia inquietante.

**Radio / Walkie-Talkie** _(character)_  
`comp(gateThresh -45, ratio 3) → biquad(type HP, freq 400, q 0.9) → biquad(type LP, freq 3000, q 0.9) → distortion(drive 4, mix 0.6)[oversampled] → noise(level 0.03, color 0.2) → master(outGain 1.0)`  
Band-pass estrecho + distorsión SIN aliasing (antes sonaba a fritura digital) + pizca de estática = realismo de transmisión. Gate para silencios limpios.

**Teléfono** _(character)_  
`biquad(type HP, freq 300, q 0.707) → biquad(type LP, freq 3400, q 0.707) → distortion(drive 2, mix 0.3)[oversampled] → master(outGain 1.0)`  
Band-pass GSM/PSTN 300-3400 estándar + grit muy leve para 'línea mala'. Mínimo y exacto.

**Megáfono / PA** _(character)_  
`comp(gateThresh -42, ratio 4) → biquad(type HP, freq 500, q 0.8) → biquad(type LP, freq 4000, q 0.8) → distortion(drive 12, mix 0.85)[oversampled] → reverb(roomsize 0.30, wet 0.15) → master(outGain 0.95)`  
Band-pass + distorsión FUERTE (cono saturado) ahora sin aliasing áspero; reverb leve = 'PA en estadio'. El limitador master evita que truene con drive 12.

**Autotune (T-Pain/Cher)** _(character)_  
`comp(gateThresh -45, ratio 3, compThresh -18) → pitch(semitones 0, formant 1.0, autotune 1, scale 2, retuneMs 0)[phase-locked] → chorus(rate 0.4, depth 0.3, mix 0.3) → biquad(type PEAK, freq 4000, q 1.0, gainDb +3) → master(outGain 1.0)`  
retune 0 = el quiebre robótico característico (reusa la f0 del PV ya calculada). Chorus leve + presencia a 4k pulen el efecto cantado.

**Locutor FM Premium (pre-master)** _(room)_  
`comp(gateThresh -45, gateRel 130, ratio 4, compThresh -18, attack 10, release 100, makeup 4) → biquad(type LOWSHELF, freq 120, gainDb +2) → biquad(type PEAK, freq 3500, q 1.0, gainDb +4) → distortion(drive 1.8, mix 0.3)[oversampled] → master(outGain 1.0)`  
Sin pitch ni efectos raros: la receta que hace que CUALQUIER voz suene profesional. Sirve de base/'pre' y demuestra el valor del compresor+EQ nuevos.

## Reglas de mastering

- ORDEN CANÓNICO de cadena en TODOS los presets: 1) Gate (dentro del comp), 2) EQ correctiva / HP de limpieza (pre-énfasis), 3) Pitch/Formant, 4) No-lineal SOBREMUESTREADO (distortion/ringmod), 5) Modulación (tremolo/vibrato/chorus/flanger/ringmod alto), 6) EQ de carácter (post-shaping, peaking/shelf), 7) Tiempo (delay → reverb), 8) Makeup gain, 9) Limitador master. El gate primero evita amplificar ruido; el limitador al final controla picos tras distorsión y reverb.
- Gate ANTES del drive en todo preset con distorsión: distorsión+ganancia amplifican TODO incluido el hiss del micro. Sin gate, los silencios entre frases se llenan de estática que 'respira' con la distorsión. (No confundir con el efecto noise, que SUMA estática decorativa.)
- Anti-aliasing OBLIGATORIO en toda no linealidad: distortion oversampleada x2 o ADAA, y ringmod band-limitada. A 16k Nyquist=8kHz y el aliasing se pliega justo en la banda de voz → es lo que más delata 'barato'. Ningún preset debe usar drive alto sin esta protección.
- Iguala el LOUDNESS percibido, no el volumen: ajusta master.outGain por preset para que cambiar de voz NO salte de nivel (más fuerte ≠ mejor). Mantén wetMix=1.0 en personajes (transformación total) y <1.0 solo donde la inteligibilidad importe. El wet de reverb/delay controla profundidad, no volumen global.
- Limitador master a -1 dBFS SIEMPRE el último, con el softClamp(tanh) como red dura DESPUÉS de él. Así ningún preset truena aunque subas outGain para igualar loudness o aunque la reverb/delay generen picos.
- Reverb wet BAJO (0.12-0.20) en voces de personaje (demonio, monstruo, narrador, gigante); wet alto (0.40-0.55) SOLO en voces de espacio explícito (cueva, iglesia, fantasma). Reverb alto en personaje mata la inteligibilidad en una llamada de voz.
- Separa SIEMPRE pitch de formant: al subir pitch, sube formant MENOS que el ratio (o bájalo) para sonar 'otra criatura' y no 'cinta acelerada'. Al bajar, baja también formant para dar cuerpo de tracto grande (pero >0.72 o se embarra).
- Pitch con phase-locking + protección de transitorios activos en shifts grandes (±6 st o más), y LP suave (~6-6.5kHz) tras pitch-ups extremos para domar el aliasing chillón en 16k. Acepta techo de pitch-up ~+10 st (sin aire que subir más allá).
- Realismo de radio/teléfono/megáfono = band-pass (HP+LP) + distorsión leve + pizca de noise, las TRES capas juntas; nunca un solo filtro.
- Todo parámetro nuevo pasa por el Smoother existente (next/snap, ~50ms) y todo feedback por undenorm()/FTZ; cualquier buffer (vibrato/flanger/comb/bitcrush hold/limiter lookahead) se pre-aloca en prepare(), NUNCA malloc/lock en process(). Rampa formantRatio 20-50ms para evitar morphing chirriante.
- Checklist por preset antes de publicarlo: (1) ¿gate+HP antes del drive? (2) ¿no-lineal sobremuestreado? (3) ¿EQ correctiva antes y de carácter después? (4) ¿loudness igualado al dry (outGain)? (5) ¿reverb/delay cortos salvo salas? (6) ¿pitch con formantes preservados y transitorios protegidos? (7) ¿limitador a -1 dBFS? (8) ¿suena humano/intencional, no digital roto? Si falla 1-2, ahí está el amateur.

## Orden de implementación

1. FASE 0 — Mastering (máximo ROI, sube TODOS los presets): añadir nodo VFX_COMP (compresor+gate, type 9) y reemplazar el softClamp del master por un limitador brickwall real a -1 dBFS (voicefx.cpp). Esto solo ya acerca toda la biblioteca a 'producido'.
2. FASE 1 — Anti-aliasing: oversampling/ADAA en VFX_DISTORTION y band-limit en VFX_RINGMOD (effects.cpp). Quita el sonido 'avispero/fritura' que más delata barato a 16k.
3. FASE 2 — EQ paramétrico: extender VFX_BIQUAD con PEAKING/LOWSHELF/HIGHSHELF + param GAIN_DB=303 (effects.cpp computeCoeffs + presets.dart rangos). Habilita presencia/calidez/anti-boxiness en todos los presets.
4. FASE 3 — Pitch de calidad: identity phase-locking + protección de transitorios + manejo unvoiced en pitch.cpp (sin FFTs extra). Convierte los personajes con pitch fuerte en creíbles nivel Voicemod.
5. FASE 4 — Efectos nuevos baratos para variedad: VFX_BITCRUSH (type 10), VFX_VIBRATO (11), VFX_FLANGER (12) — los tres reusan patrones existentes. Habilitan Dalek auténtico, anciano realista y robots resonantes.
6. FASE 5 — Reutilizar el PV: AUTOTUNE (params 602-604) y SUB-OCTAVE (param 605) dentro del nodo pitch. Habilita voces cantadas y el growl/wall-of-voice de monstruo.
7. FASE 6 — Reescribir el CATÁLOGO de presets (voice_fx_presets.dart + assets/voicefx_presets.json) aplicando el orden canónico, gate, anti-alias, EQ de carácter, makeup gain igualado y los nuevos efectos. Hornear los 20+ presets del blueprint.
8. FASE 7 — Sci-fi avanzado (opcional): VFX_FREQSHIFT (type 13) para aliens shimmering que el ringmod no logra.
9. FASE 8 — Estructural (último, alto riesgo/alto impacto): recuperar fullband (correr voicefx sobre el recombinado a 48k en rnnoise_processor.cc) para ganar aire >8kHz. Hacerlo SOLO tras exprimir todo lo barato en 16k.
10. En cada fase que toque la ABI: añadir enum al FINAL antes de _COUNT (nunca renumerar), subir VFX_EFFECT_TYPE_COUNT y VOICEFX_ABI_VERSION, espejar en voice_fx.dart (enum + kVfxP* + registry + labelEs) y _kParamRanges en presets.dart, recompilar el fork + flutter clean (cambió webrtc).

## Primer paso
Implementar el nodo VFX_COMP (compresor + noise gate, type 9) en el fork: 1) en voicefx.h añadir VFX_COMP al final del enum VfxEffectType (antes de _COUNT), subir VFX_EFFECT_TYPE_COUNT y VOICEFX_ABI_VERSION, y declarar el bloque de params 1000..1006 (GATE_THRESH=1000, GATE_RELEASE=1001, RATIO=1002, COMP_THRESH=1003, ATTACK=1004, RELEASE=1005, MAKEUP=1006); 2) en effects.hpp declarar class CompGate : public Effect con detector de envolvente RMS de 1 polo (estado fijo, sin buffers grandes); 3) en effects.cpp implementar process() (gate atenúa bajo umbral → compresor ratio/attack/release → makeup), añadir las 7 filas a kParamTable y registrar en createEffect(); 4) espejar en voice_fx.dart (VoiceFxType.comp al final, constantes kVfxP*, registry, labelEs) y en _kParamRanges de voice_fx_presets.dart; 5) recompilar el fork + flutter clean. Es el cambio de mayor impacto/menor esfuerzo: un solo nodo realtime-safe sin tocar la arquitectura serie, y mejora la calidad PERCIBIDA de toda la biblioteca de presets de golpe. En paralelo (mismo PR o el siguiente, también barato y sin nuevo nodo) reemplazar el softClamp del master por un limitador brickwall a -1 dBFS en voicefx.cpp.


---
## Verificación adversarial (ingeniero de audio escéptico)

**Veredicto:** sólido


### Riesgos realtime

- LATENCIA DEL PV YA ESTÁ FUERA DE PRESUPUESTO Y EL BLUEPRINT NO LO MENCIONA. pitch.hpp dice 'kLatency=768=16ms@48kHz', pero rnnoise_processor.cc llama vfx_create(sr=16000). A 16k, 768 muestras = 48 ms de latencia algorítmica del shifter, ya POR ENCIMA del budget de 30 ms de CONTRACT.md. Cualquier preset con pitch ya está en zona de eco perceptible en una llamada. Autotune/sub-octave que REUSAN ese front-end heredan los 48 ms. Antes de añadir nada al PV hay que decidir N/hop más cortos (p.ej. N=512/hop=128 = 24 ms) o asumir explícitamente la latencia. El blueprint trata el PV como 'gratis de reusar' ignorando que ya es el componente más caro y más lento.
- AUTOTUNE con retuneMs=0 NO es realista de implementar bien sobre ESTE PV. La f0 robusta a partir de trueBin_/cepstrum en mono 16k con susurro/ruido es exactamente el problema frágil que el propio blueprint dice evitar en PSOLA, y luego lo reintroduce. Peor: el shifter actual mueve magnitudes con redondeo entero (synMag_[round(k*P)] +=) y NO tiene phase-locking; forzar el ratio dinámicamente sin phase-locking producirá warbling/gargarismo en cada nota, no el quiebre limpio T-Pain. Autotune debe ir DESPUÉS del phase-locking, nunca antes, y aún así el retune 0 duro es 1.5 días optimistas; cuenta 3-4 con tuning de f0.
- SUB-OCTAVE 'intra-pitch' (param 605) NO es casi gratis como afirma. El PV actual es monofónico en su síntesis: una sola pasada de phase accumulation sobre synMag_/synBin_. Sumar una copia a -12 st requiere un SEGUNDO conjunto de synMag/synBin/sumPhase y un segundo recolor+acumulación de fase independiente (si compartes sumPhase_ los dos pitches se pelean la fase y suena a metálico). Es O(bins) extra pero NO trivial y duplica el estado de fase. Realista, pero no 'segundo recolor de la misma FFT casi gratis'.
- FREQUENCY SHIFTER por Hilbert (all-pass de cuadratura IIR) es la pieza con peor relación valor/riesgo en mono 16k: los pares all-pass de cuadratura solo dan 90° de error bajo en una banda limitada y a 16k con techo de 8k el error de fase en extremos genera la imagen residual (el tono fantasma) que delata 'barato'. Es delicado de afinar, impacto declarado 'bajo' por el propio autor. Cortar.
- REVERB 'roomsize 0.90 / wet 0.55' (Fantasma) en mono 16k realtime: el reverb actual es un nodo en serie; colas largas con wet alto en banda 0 suenan a lata metálica porque no hay difusión >8k. No es un glitch de hilo de audio, pero sí una promesa de calidad que 16k mono no entrega: el reverb largo en mono limitado a 8k es justo donde más se nota la falta de aire.

### Promesas a moderar (techo de 16 kHz)

- Presets 'Chica/Niño/Helio' con peak a 3.5-4 kHz para 'aire/presencia femenina' y 'brillo': a 16k Nyquist=8k y la banda 0 está fuertemente atenuada arriba de ~7k. El 'aire' de voz femenina/niño vive en 8-14 kHz — NO EXISTE en 16k. Un peak a 3.5-4k da presencia de medios-altos, no 'aire'; describirlo como 'aire femenino' sobreentrega. Esas voces sonarán correctas pero apagadas/sin brillo hasta que se haga la Fase 8 (fullband). Honestidad: en 16k son 'aceptables', no 'increíbles nivel Voicemod'.
- 'Helio/Munchkin +10 st': prácticamente todo el contenido útil tras +10 st en 16k cae fuera de banda; el resultado será fino y aliaseado pese al LP. Promesa de 'munchkin clásico' limitada por el ancho de banda.
- 'Alien Shimmering' con chorus 'para shimmer etéreo en mono': el shimmer/chorus en MONO con una sola línea de delay no da el ancho estéreo que la palabra 'shimmer' evoca; en mono es solo un leve detune/comb. Funciona, pero no es el efecto que el nombre promete.
- El visionSummary dice que recuperar fullband es 'el mayor ROI estructural' y a la vez lo pone en Fase 8 (último, alto riesgo). Correcto priorizar lo barato primero, pero hay tensión: varias promesas de calidad ('mujer creíble con aire', 'brillo') DEPENDEN de fullband. No se puede prometer 'nivel Voicemod' en voces agudas sin la Fase 8; el blueprint debería marcar explícitamente qué presets quedan 'capados' hasta fullband.

### Correcciones

- Phase-locking: la propuesta es CORRECTA y necesaria — pero el código real es PEOR de lo que el blueprint asume. pitch.cpp no propaga fase coherente: dispersa magnitud con synMag_[round(k*P)] += y acumula fase con synBin_*expct sin region-of-influence. No es 'quitar phasiness a un PV decente', es 'arreglar un PV crudo'. Identity phase-locking de Laroche-Dolson aquí es 3-4 días, no 2, porque hay que reescribir el bloque de síntesis (1.176-1.200), no solo añadir herencia de fase. Sigue siendo el upgrade #1 de pitch, pero el effort está subestimado.
- Limitador 'lookahead 16-32 muestras = 1-2 ms a 16k': correcto el número, pero AÑADE latencia al master encima de los 48 ms del PV. En una llamada de voz el lookahead suma; usa 8-16 muestras (0.5-1 ms) o un limitador feedforward sin lookahead (peak hold + release rápido) para no empeorar el budget ya comprometido.
- Anti-aliasing: ADAA de 1er orden sobre tanh es correcto y barato, PERO ADAA tiene el problema clásico de divergencia 0/0 cuando dos muestras consecutivas son casi iguales (denominador →0); hay que añadir el fallback a la derivada puntual cuando |x[n]-x[n-1]|<eps. El blueprint lo vende como 'casi gratis, 1 muestra de memoria' sin mencionar esa trampa numérica, que SÍ produce clicks en señal cuasi-DC (silencios, vocales sostenidas). Documentar el eps-guard como obligatorio.
- RingMod band-limit: el LP 'tras la multiplicación' NO elimina el aliasing — el aliasing ya se plegó dentro de banda ANTES del LP. Para band-limitar ringmod de verdad necesitas limitar el carrier (freq baja) Y oversamplear la multiplicación, igual que la distorsión. Un LP post solo recorta el lado alto legítimo. La afirmación de que 'un LP suave tras la multiplicación' arregla el plegado es técnicamente incorrecta.
- Compresor+gate con detector RMS de 1 polo: bien, pero el orden 'gate atenúa bajo umbral → compresor' con un solo detector RMS compartido hará que el gate y el compresor reaccionen a la misma envolvente lenta; un gate decente necesita su propio detector más rápido (peak o RMS muy corto) o se 'comerá' los ataques de palabra. Es realtime-safe, pero el resultado será suave/blando si comparten envolvente. Dos detectores baratos, no uno.
- Techo de pitch-up: +10/+12 st 'sin agudos que subir' es correcto pero incompleto — a 16k el aliasing del pitch-up grande es severísimo porque el shifter mueve bins por encima de Nyquist/P. El LP a 6-6.5k es obligatorio (el blueprint lo dice) pero ADEMÁS hay que descartar bins origen k donde k*P>kBins en vez de envolverlos. Verificar que el continue de pitch.cpp:183 ya lo hace (sí lo hace para idx>kBins), bien.

### Quick wins (empezar YA)

- FASE 0a — Limitador brickwall en el master (voicefx.cpp, reemplazar softClamp en líneas ~58-65/263-269). Es medio día REAL, no toca ABI, no añade nodo, y arregla el 'truena' de TODOS los presets con drive/reverb. Usa feedforward con lookahead de 8 muestras (0.5 ms) para no sumar latencia. Mayor impacto / menor esfuerzo / menor riesgo de todo el plan. EMPEZAR AQUÍ HOY.
- FASE 0b — Nodo VFX_COMP (compresor+gate, type 9). El patrón Param/Smoother y el enum-al-final-antes-de-_COUNT ya están establecidos; effects.hpp/cpp y el espejo en voice_fx.dart son mecánicos. ~1 día. Sube la calidad PERCIBIDA de toda la biblioteca de golpe (dinámica controlada = 'producido'). Único matiz: dale al gate su propio detector rápido, no compartas envolvente con el compresor.
- FASE 2 — EQ peaking/lowshelf/highshelf extendiendo VFX_BIQUAD (TYPE 4/5/6 + GAIN_DB=303). Verificado en effects.cpp:236-266: son 3 casos RBJ más en computeCoeffs() que ya recibe freq/q y ya recomputa por bloque. Medio día real, compatible, sin nodo nuevo. Es el 'pegamento' que falta para presencia/calidez/anti-boxiness. Hacerlo junto con FASE 0 en el mismo PR.
- Anti-aliasing en Distortion vía ADAA (effects.cpp:343-353), CON el eps-guard obligatorio para el caso cuasi-DC. ~1 día. Quita el 'avispero' de megáfono/demonio/radio que es lo que más delata barato a 16k. Alto impacto. (NO tocar ringmod con un simple LP post: eso no arregla el aliasing — dejar ringmod para cuando se haga oversampling de verdad.)
- Reescribir SOLO los presets que NO dependen del PV ni de efectos nuevos aplicando gate+EQ+limitador+makeup igualado: 'Locutor FM Premium', 'Teléfono', 'Radio', 'Megáfono', 'Narrador'. Demuestran el valor del mastering inmediatamente con cero código de pitch nuevo. Estos sí pueden sonar 'pro' en 16k porque no piden aire de agudos.

### Recomendación final
El blueprint es técnicamente sólido y honesto sobre la restricción de 16k mono; la tesis central — 'la brecha con Voicemod es mastering + anti-alias + un PV más limpio, no IA' — es correcta y bien fundamentada en el código real. Apruébalo, pero con tres correcciones de realidad ANTES de ejecutar: (1) El PV YA cuesta 48 ms de latencia a 16k (no 16 ms como dice el comentario, que asume 48 kHz); decide reducir N/hop o aceptar la latencia explícitamente antes de apilarle autotune/sub-octave encima — esto el blueprint lo omite por completo y es el riesgo #1. (2) Re-presupuesta el pitch: el código real es un PV crudo (dispersión por redondeo, sin coherencia de fase), así que phase-locking es 3-4 días reescribiendo síntesis, no 2; y autotune-duro (retune 0) es 3-4 días, no 1.5, por la f0 robusta. (3) Marca como sobre-ingeniería para cortar/posponer: frequency shifter Hilbert (impacto bajo, riesgo alto en 16k) y la promesa de 'aire/brillo femenino' que 16k físicamente no puede dar hasta la Fase 8 (fullband). Ejecuta EXACTAMENTE en el orden de fases propuesto — es correcto — pero arranca YA con el paquete barato y de bajo riesgo: limitador master + VFX_COMP + EQ peaking/shelf + ADAA en distortion, y reescribe primero los presets sin pitch (FM/teléfono/radio/megáfono/narrador) para mostrar la mejora de inmediato. Eso sube toda la biblioteca sin tocar el PV ni la latencia.
