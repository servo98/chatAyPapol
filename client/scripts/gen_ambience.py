#!/usr/bin/env python3
"""Genera clips de AMBIENTE de sala loopables (seamless) para ChatPapol.

Estos son beds sintéticos (sin dependencias externas, solo stdlib) pensados como
placeholders/base: ruido filtrado + osciladores. La sala los reproduce en
sincronía vía el gateway (NO por WebRTC) — ver lib/ambience.dart.

El pack "bonito" se puede sustituir dejando WAVs con el mismo nombre en
assets/ambience/ y manteniendo assets/ambience_manifest.json. Royalty-free:
freesound.org (CC0) es buena fuente.

Uso:  python3 scripts/gen_ambience.py
Salida: assets/ambience/<id>.wav (mono 48k 16-bit, ~10s, loop sin click).
"""
import math
import os
import struct
import wave

SR = 48000
DUR = 10.0            # segundos del loop
XF = 0.75            # crossfade para loop sin click (s)
N = int(DUR * SR)
M = int(XF * SR)
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "ambience")


class RNG:
    """LCG determinista: clips reproducibles entre máquinas."""
    def __init__(self, seed): self.s = seed & 0xFFFFFFFF
    def f(self):
        self.s = (1103515245 * self.s + 12345) & 0x7FFFFFFF
        return self.s / 0x3FFFFFFF - 1.0   # ~[-1,1]


def one_pole(buf, a):
    """Lowpass one-pole in-place (a=0 abierto, a→1 oscuro)."""
    y = 0.0
    for i in range(len(buf)):
        y = a * y + (1 - a) * buf[i]
        buf[i] = y
    return buf


def hum_freq(f0):
    """Cuantiza f0 a un nº entero de ciclos en N muestras → fase continua en el seam."""
    cycles = max(1, round(f0 * N / SR))
    return cycles * SR / N


def seamless(s):
    """s tiene N+M muestras; devuelve N con crossfade del 'overtail' en la cabeza."""
    out = s[:N]
    for k in range(M):
        w = k / M
        out[k] = s[k] * w + s[N + k] * (1 - w)
    return out


def norm(buf, peak):
    mx = max(1e-9, max(abs(x) for x in buf))
    g = peak / mx
    return [x * g for x in buf]


def write(name, buf):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = bytearray()
        for x in buf:
            v = int(max(-1.0, min(1.0, x)) * 32767)
            frames += struct.pack("<h", v)
        w.writeframes(bytes(frames))
    print("  ->", os.path.relpath(path))


def gen_rain(seed=11):
    r = RNG(seed)
    total = N + M
    base = [r.f() for _ in range(total)]
    bright = list(base)
    one_pole(bright, 0.5)          # lluvia: ruido más bien brillante
    # gotas sueltas más fuertes
    drops = [0.0] * total
    i = 0
    while i < total:
        i += int(200 + (r.f() + 1) * 1500)
        if i < total:
            drops[i] += (r.f()) * 0.8
    one_pole(drops, 0.2)
    mix = [bright[k] * 0.7 + drops[k] for k in range(total)]
    return norm(seamless(mix), 0.55)


def gen_wind(seed=22):
    r = RNG(seed)
    total = N + M
    brown, y = [0.0] * total, 0.0
    for i in range(total):
        y = (y + r.f() * 0.05)
        y = max(-1, min(1, y * 0.999))
        brown[i] = y
    one_pole(brown, 0.92)          # viento: oscuro
    # ráfagas: LFO lento de amplitud
    out = []
    for i in range(total):
        lfo = 0.55 + 0.45 * math.sin(2 * math.pi * 0.07 * i / SR)
        out.append(brown[i] * lfo)
    return norm(seamless(out), 0.5)


def gen_cave(seed=33):
    r = RNG(seed)
    total = N + M
    rumble, y = [0.0] * total, 0.0
    for i in range(total):
        y = (y + r.f() * 0.04)
        y = max(-1, min(1, y * 0.999))
        rumble[i] = y
    one_pole(rumble, 0.985)        # cueva: rumor grave profundo
    # goteo: pings con decaimiento rápido, espaciados
    drips = [0.0] * total
    i = 0
    while i < total:
        i += int(SR * (0.8 + (r.f() + 1) * 1.4))
        if i < total:
            f = 700 + (r.f() + 1) * 500
            for k in range(int(0.25 * SR)):
                if i + k < total:
                    env = math.exp(-k / (0.05 * SR))
                    drips[i + k] += math.sin(2 * math.pi * f * k / SR) * env * 0.5
    mix = [rumble[k] * 0.8 + drips[k] for k in range(total)]
    return norm(seamless(mix), 0.5)


def gen_scifi(seed=44):
    total = N + M
    f1, f2, f3 = hum_freq(55), hum_freq(55.4), hum_freq(110.2)
    r = RNG(seed)
    shimmer = [r.f() for _ in range(total)]
    one_pole(shimmer, 0.6)
    one_pole(shimmer, 0.6)
    out = []
    for i in range(total):
        trem = 0.85 + 0.15 * math.sin(2 * math.pi * 0.2 * i / SR)
        s = (math.sin(2 * math.pi * f1 * i / SR) * 0.5 +
             math.sin(2 * math.pi * f2 * i / SR) * 0.4 +
             math.sin(2 * math.pi * f3 * i / SR) * 0.2)
        out.append((s * trem + shimmer[i] * 0.12))
    return norm(seamless(out), 0.5)


def gen_fire(seed=55):
    r = RNG(seed)
    total = N + M
    rumble = [r.f() for _ in range(total)]
    one_pole(rumble, 0.96)
    crack = [0.0] * total
    i = 0
    while i < total:
        i += int(80 + (r.f() + 1) * 900)
        if i < total:
            for k in range(int(0.02 * SR)):
                if i + k < total:
                    crack[i + k] += r.f() * math.exp(-k / (0.004 * SR)) * 0.9
    mix = [rumble[k] * 0.5 + crack[k] for k in range(total)]
    return norm(seamless(mix), 0.55)


def gen_ocean(seed=66):
    r = RNG(seed)
    total = N + M
    foam = [r.f() for _ in range(total)]
    one_pole(foam, 0.86)
    out = []
    for i in range(total):
        # olas: dos LFOs lentos sumados para que el swell no sea monótono
        swell = (0.5 + 0.5 * math.sin(2 * math.pi * 0.09 * i / SR)) * \
                (0.6 + 0.4 * math.sin(2 * math.pi * 0.037 * i / SR + 1.3))
        out.append(foam[i] * swell)
    return norm(seamless(out), 0.5)


GENS = {
    "rain": gen_rain, "wind": gen_wind, "cave": gen_cave,
    "scifi": gen_scifi, "fire": gen_fire, "ocean": gen_ocean,
}

if __name__ == "__main__":
    print("Generando ambientes loopables en assets/ambience/ ...")
    for name, fn in GENS.items():
        write(name, fn())
    print("Listo.")
