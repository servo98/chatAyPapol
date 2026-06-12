/* ============================================================================
 * voicefx_cli.cpp — standalone test harness for libvoicefx (no Flutter).
 *
 * Reads a WAV (16-bit PCM or 32-bit float, mono/stereo -> mono), or generates
 * a 3 s sine sweep if no --in is given. Builds a chain through the public
 * C ABI (preset name or --fx specs), processes block-by-block (10 ms blocks,
 * same as the runtime capture path), and writes a 16-bit mono WAV.
 *
 * Usage:
 *   voicefx_cli --list
 *   voicefx_cli --preset cueva [--in voz.wav] [--out out.wav]
 *   voicefx_cli --fx reverb:roomsize=0.9,wet=0.5 --fx delay:timeMs=200 \
 *               [--wet 1.0] [--gain 1.0] [--in voz.wav] [--out out.wav]
 *
 * Preset definitions mirror CONTRACT.md §5 exactly (same values that will
 * live in assets/voicefx_presets.json).
 * ==========================================================================*/

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../include/voicefx.h"

/* ============================== name tables ============================== */

struct FxName {
  const char* name;
  int type;
};
static const FxName kFxNames[] = {
    {"reverb", VFX_REVERB},   {"delay", VFX_DELAY},
    {"biquad", VFX_BIQUAD},   {"ringmod", VFX_RINGMOD},
    {"distortion", VFX_DISTORTION}, {"pitch", VFX_PITCH},
    {"noise", VFX_NOISE},     {"tremolo", VFX_TREMOLO},
    {"chorus", VFX_CHORUS},
};

struct ParamName {
  int type;
  const char* key; /* JSON key from CONTRACT.md §3 */
  int id;
};
static const ParamName kParamNames[] = {
    {VFX_REVERB, "roomsize", VFX_P_REVERB_ROOMSIZE},
    {VFX_REVERB, "damp", VFX_P_REVERB_DAMP},
    {VFX_REVERB, "wet", VFX_P_REVERB_WET},
    {VFX_DELAY, "timeMs", VFX_P_DELAY_TIME_MS},
    {VFX_DELAY, "feedback", VFX_P_DELAY_FEEDBACK},
    {VFX_DELAY, "mix", VFX_P_DELAY_MIX},
    {VFX_BIQUAD, "type", VFX_P_BIQUAD_TYPE},
    {VFX_BIQUAD, "freq", VFX_P_BIQUAD_FREQ},
    {VFX_BIQUAD, "q", VFX_P_BIQUAD_Q},
    {VFX_RINGMOD, "freq", VFX_P_RINGMOD_FREQ},
    {VFX_RINGMOD, "mix", VFX_P_RINGMOD_MIX},
    {VFX_DISTORTION, "drive", VFX_P_DIST_DRIVE},
    {VFX_DISTORTION, "mix", VFX_P_DIST_MIX},
    {VFX_PITCH, "semitones", VFX_P_PITCH_SEMITONES},
    {VFX_PITCH, "formant", VFX_P_PITCH_FORMANT},
    {VFX_NOISE, "level", VFX_P_NOISE_LEVEL},
    {VFX_NOISE, "color", VFX_P_NOISE_COLOR},
    {VFX_TREMOLO, "rate", VFX_P_TREMOLO_RATE},
    {VFX_TREMOLO, "depth", VFX_P_TREMOLO_DEPTH},
    {VFX_CHORUS, "rate", VFX_P_CHORUS_RATE},
    {VFX_CHORUS, "depth", VFX_P_CHORUS_DEPTH},
    {VFX_CHORUS, "mix", VFX_P_CHORUS_MIX},
};

static int fxTypeByName(const char* name) {
  for (const FxName& f : kFxNames) {
    if (std::strcmp(f.name, name) == 0) return f.type;
  }
  return -1;
}

static int paramIdByKey(int type, const char* key) {
  for (const ParamName& p : kParamNames) {
    if (p.type == type && std::strcmp(p.key, key) == 0) return p.id;
  }
  return -1;
}

/* =========================== canonical presets ============================ */
/* Exact values from CONTRACT.md §5. */

struct PParam {
  int id;
  float value;
};
struct PNode {
  int type;
  PParam params[4];
  int nParams;
};
struct Preset {
  const char* id;
  PNode nodes[4];
  int nNodes;
};

static const Preset kPresets[] = {
    /* --- rooms --- */
    {"cueva",
     {{VFX_REVERB, {{VFX_P_REVERB_ROOMSIZE, 0.92f}, {VFX_P_REVERB_DAMP, 0.25f}, {VFX_P_REVERB_WET, 0.55f}}, 3},
      {VFX_DELAY, {{VFX_P_DELAY_TIME_MS, 180.0f}, {VFX_P_DELAY_FEEDBACK, 0.45f}, {VFX_P_DELAY_MIX, 0.30f}}, 3}},
     2},
    {"iglesia",
     {{VFX_REVERB, {{VFX_P_REVERB_ROOMSIZE, 0.85f}, {VFX_P_REVERB_DAMP, 0.60f}, {VFX_P_REVERB_WET, 0.45f}}, 3}},
     1},
    {"sala",
     {{VFX_REVERB, {{VFX_P_REVERB_ROOMSIZE, 0.25f}, {VFX_P_REVERB_DAMP, 0.70f}, {VFX_P_REVERB_WET, 0.22f}}, 3}},
     1},
    {"eco",
     {{VFX_DELAY, {{VFX_P_DELAY_TIME_MS, 400.0f}, {VFX_P_DELAY_FEEDBACK, 0.50f}, {VFX_P_DELAY_MIX, 0.45f}}, 3}},
     1},
    {"radio",
     {{VFX_BIQUAD, {{VFX_P_BIQUAD_TYPE, 1.0f}, {VFX_P_BIQUAD_FREQ, 400.0f}, {VFX_P_BIQUAD_Q, 0.9f}}, 3},
      {VFX_BIQUAD, {{VFX_P_BIQUAD_TYPE, 0.0f}, {VFX_P_BIQUAD_FREQ, 3000.0f}, {VFX_P_BIQUAD_Q, 0.9f}}, 3},
      {VFX_DISTORTION, {{VFX_P_DIST_DRIVE, 4.0f}, {VFX_P_DIST_MIX, 0.6f}}, 2},
      {VFX_NOISE, {{VFX_P_NOISE_LEVEL, 0.03f}, {VFX_P_NOISE_COLOR, 0.2f}}, 2}},
     4},
    {"telefono",
     {{VFX_BIQUAD, {{VFX_P_BIQUAD_TYPE, 1.0f}, {VFX_P_BIQUAD_FREQ, 300.0f}, {VFX_P_BIQUAD_Q, 0.707f}}, 3},
      {VFX_BIQUAD, {{VFX_P_BIQUAD_TYPE, 0.0f}, {VFX_P_BIQUAD_FREQ, 3400.0f}, {VFX_P_BIQUAD_Q, 0.707f}}, 3}},
     2},
    {"megafono",
     {{VFX_BIQUAD, {{VFX_P_BIQUAD_TYPE, 1.0f}, {VFX_P_BIQUAD_FREQ, 500.0f}, {VFX_P_BIQUAD_Q, 0.8f}}, 3},
      {VFX_BIQUAD, {{VFX_P_BIQUAD_TYPE, 0.0f}, {VFX_P_BIQUAD_FREQ, 4000.0f}, {VFX_P_BIQUAD_Q, 0.8f}}, 3},
      {VFX_DISTORTION, {{VFX_P_DIST_DRIVE, 12.0f}, {VFX_P_DIST_MIX, 0.85f}}, 2}},
     3},
    {"robot",
     {{VFX_RINGMOD, {{VFX_P_RINGMOD_FREQ, 35.0f}, {VFX_P_RINGMOD_MIX, 0.8f}}, 2},
      {VFX_DELAY, {{VFX_P_DELAY_TIME_MS, 50.0f}, {VFX_P_DELAY_FEEDBACK, 0.40f}, {VFX_P_DELAY_MIX, 0.30f}}, 3}},
     2},
    {"scifi",
     {{VFX_CHORUS, {{VFX_P_CHORUS_RATE, 0.6f}, {VFX_P_CHORUS_DEPTH, 0.7f}, {VFX_P_CHORUS_MIX, 0.6f}}, 3},
      {VFX_RINGMOD, {{VFX_P_RINGMOD_FREQ, 200.0f}, {VFX_P_RINGMOD_MIX, 0.2f}}, 2},
      {VFX_REVERB, {{VFX_P_REVERB_ROOMSIZE, 0.5f}, {VFX_P_REVERB_DAMP, 0.5f}, {VFX_P_REVERB_WET, 0.25f}}, 3}},
     3},
    /* --- characters --- */
    {"troll",
     {{VFX_PITCH, {{VFX_P_PITCH_SEMITONES, -8.0f}, {VFX_P_PITCH_FORMANT, 0.78f}}, 2},
      {VFX_DISTORTION, {{VFX_P_DIST_DRIVE, 5.0f}, {VFX_P_DIST_MIX, 0.35f}}, 2},
      {VFX_REVERB, {{VFX_P_REVERB_ROOMSIZE, 0.90f}, {VFX_P_REVERB_DAMP, 0.30f}, {VFX_P_REVERB_WET, 0.40f}}, 3}},
     3},
    {"demonio",
     {{VFX_PITCH, {{VFX_P_PITCH_SEMITONES, -6.0f}, {VFX_P_PITCH_FORMANT, 0.80f}}, 2},
      {VFX_DISTORTION, {{VFX_P_DIST_DRIVE, 9.0f}, {VFX_P_DIST_MIX, 0.50f}}, 2},
      {VFX_REVERB, {{VFX_P_REVERB_ROOMSIZE, 0.80f}, {VFX_P_REVERB_DAMP, 0.40f}, {VFX_P_REVERB_WET, 0.35f}}, 3}},
     3},
    {"viejo",
     {{VFX_PITCH, {{VFX_P_PITCH_SEMITONES, -1.5f}, {VFX_P_PITCH_FORMANT, 0.92f}}, 2},
      {VFX_TREMOLO, {{VFX_P_TREMOLO_RATE, 6.5f}, {VFX_P_TREMOLO_DEPTH, 0.35f}}, 2},
      {VFX_BIQUAD, {{VFX_P_BIQUAD_TYPE, 0.0f}, {VFX_P_BIQUAD_FREQ, 4000.0f}, {VFX_P_BIQUAD_Q, 0.707f}}, 3}},
     3},
    {"ardilla",
     {{VFX_PITCH, {{VFX_P_PITCH_SEMITONES, 10.0f}, {VFX_P_PITCH_FORMANT, 1.30f}}, 2}},
     1},
    {"nino",
     {{VFX_PITCH, {{VFX_P_PITCH_SEMITONES, 4.0f}, {VFX_P_PITCH_FORMANT, 1.20f}}, 2}},
     1},
    /* --- gender --- */
    {"hombre_a_mujer",
     {{VFX_PITCH, {{VFX_P_PITCH_SEMITONES, 4.0f}, {VFX_P_PITCH_FORMANT, 1.20f}}, 2}},
     1},
    {"mujer_a_hombre",
     {{VFX_PITCH, {{VFX_P_PITCH_SEMITONES, -5.0f}, {VFX_P_PITCH_FORMANT, 0.85f}}, 2}},
     1},
};

static const Preset* findPreset(const char* id) {
  for (const Preset& p : kPresets) {
    if (std::strcmp(p.id, id) == 0) return &p;
  }
  return nullptr;
}

/* ============================== WAV I/O =================================== */
/* Minimal, self-contained, little-endian-only (fine for x86/ARM desktop). */

struct Wav {
  int sampleRate = 48000;
  std::vector<float> samples; /* mono */
};

static bool readWav(const char* path, Wav* out) {
  FILE* f = std::fopen(path, "rb");
  if (!f) {
    std::fprintf(stderr, "error: cannot open '%s'\n", path);
    return false;
  }
  char id[5] = {0};
  uint8_t hdr[8];
  if (std::fread(id, 1, 4, f) != 4 || std::memcmp(id, "RIFF", 4) != 0 ||
      std::fread(hdr, 1, 4, f) != 4 || std::fread(id, 1, 4, f) != 4 ||
      std::memcmp(id, "WAVE", 4) != 0) {
    std::fprintf(stderr, "error: '%s' is not a RIFF/WAVE file\n", path);
    std::fclose(f);
    return false;
  }

  uint16_t fmt = 0, channels = 0, bits = 0;
  uint32_t rate = 0;
  std::vector<uint8_t> data;
  bool haveFmt = false, haveData = false;

  while (std::fread(hdr, 1, 8, f) == 8) {
    const uint32_t size = static_cast<uint32_t>(hdr[4]) |
                          (static_cast<uint32_t>(hdr[5]) << 8) |
                          (static_cast<uint32_t>(hdr[6]) << 16) |
                          (static_cast<uint32_t>(hdr[7]) << 24);
    if (std::memcmp(hdr, "fmt ", 4) == 0 && size >= 16) {
      uint8_t b[16];
      if (std::fread(b, 1, 16, f) != 16) break;
      fmt = static_cast<uint16_t>(b[0] | (b[1] << 8));
      channels = static_cast<uint16_t>(b[2] | (b[3] << 8));
      rate = static_cast<uint32_t>(b[4]) | (static_cast<uint32_t>(b[5]) << 8) |
             (static_cast<uint32_t>(b[6]) << 16) |
             (static_cast<uint32_t>(b[7]) << 24);
      bits = static_cast<uint16_t>(b[14] | (b[15] << 8));
      if (size > 16) std::fseek(f, static_cast<long>(size - 16), SEEK_CUR);
      haveFmt = true;
    } else if (std::memcmp(hdr, "data", 4) == 0) {
      data.resize(size);
      if (size > 0 && std::fread(data.data(), 1, size, f) != size) break;
      haveData = true;
    } else {
      std::fseek(f, static_cast<long>(size), SEEK_CUR);
    }
    if (size & 1u) std::fseek(f, 1, SEEK_CUR); /* chunk padding */
  }
  std::fclose(f);

  if (!haveFmt || !haveData || channels < 1 || channels > 2 || rate == 0) {
    std::fprintf(stderr, "error: unsupported or truncated WAV '%s'\n", path);
    return false;
  }

  out->sampleRate = static_cast<int>(rate);
  out->samples.clear();
  const float chNorm = 1.0f / static_cast<float>(channels);

  if (fmt == 1 && bits == 16) {
    const size_t frames = data.size() / (2u * channels);
    out->samples.reserve(frames);
    const uint8_t* p = data.data();
    for (size_t i = 0; i < frames; ++i) {
      float acc = 0.0f;
      for (int c = 0; c < channels; ++c) {
        const int16_t s = static_cast<int16_t>(
            static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8));
        acc += static_cast<float>(s) / 32768.0f;
        p += 2;
      }
      out->samples.push_back(acc * chNorm);
    }
  } else if (fmt == 3 && bits == 32) {
    const size_t frames = data.size() / (4u * channels);
    out->samples.reserve(frames);
    const uint8_t* p = data.data();
    for (size_t i = 0; i < frames; ++i) {
      float acc = 0.0f;
      for (int c = 0; c < channels; ++c) {
        float v;
        std::memcpy(&v, p, 4);
        acc += v;
        p += 4;
      }
      out->samples.push_back(acc * chNorm);
    }
  } else {
    std::fprintf(stderr,
                 "error: WAV must be 16-bit PCM or 32-bit float (got fmt=%u "
                 "bits=%u)\n",
                 fmt, bits);
    return false;
  }
  return true;
}

static void put32(std::vector<uint8_t>& b, uint32_t v) {
  b.push_back(static_cast<uint8_t>(v));
  b.push_back(static_cast<uint8_t>(v >> 8));
  b.push_back(static_cast<uint8_t>(v >> 16));
  b.push_back(static_cast<uint8_t>(v >> 24));
}
static void put16(std::vector<uint8_t>& b, uint16_t v) {
  b.push_back(static_cast<uint8_t>(v));
  b.push_back(static_cast<uint8_t>(v >> 8));
}

static bool writeWav(const char* path, const Wav& w) {
  const uint32_t nBytes = static_cast<uint32_t>(w.samples.size() * 2);
  std::vector<uint8_t> b;
  b.reserve(44 + nBytes);
  b.insert(b.end(), {'R', 'I', 'F', 'F'});
  put32(b, 36 + nBytes);
  b.insert(b.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
  put32(b, 16);
  put16(b, 1); /* PCM */
  put16(b, 1); /* mono */
  put32(b, static_cast<uint32_t>(w.sampleRate));
  put32(b, static_cast<uint32_t>(w.sampleRate) * 2u); /* byte rate */
  put16(b, 2);  /* block align */
  put16(b, 16); /* bits */
  b.insert(b.end(), {'d', 'a', 't', 'a'});
  put32(b, nBytes);
  for (float v : w.samples) {
    if (v > 1.0f) v = 1.0f;
    if (v < -1.0f) v = -1.0f;
    const int16_t s = static_cast<int16_t>(std::lrintf(v * 32767.0f));
    put16(b, static_cast<uint16_t>(s));
  }
  FILE* f = std::fopen(path, "wb");
  if (!f) {
    std::fprintf(stderr, "error: cannot write '%s'\n", path);
    return false;
  }
  const bool ok = std::fwrite(b.data(), 1, b.size(), f) == b.size();
  std::fclose(f);
  return ok;
}

/* 3 s log sine sweep 100 Hz -> 4 kHz @ 48 kHz, plus 1 s of tail silence so
 * reverb/delay decays are audible in the output. */
static Wav makeSweep() {
  Wav w;
  w.sampleRate = 48000;
  const int n = w.sampleRate * 3;
  const float f0 = 100.0f, f1 = 4000.0f;
  const float dur = 3.0f;
  const float k = std::log(f1 / f0);
  double phase = 0.0;
  w.samples.resize(static_cast<size_t>(n + w.sampleRate), 0.0f);
  for (int i = 0; i < n; ++i) {
    const float t = static_cast<float>(i) / static_cast<float>(w.sampleRate);
    const float f = f0 * std::exp(k * t / dur);
    phase += 2.0 * 3.14159265358979323846 * static_cast<double>(f) /
             static_cast<double>(w.sampleRate);
    w.samples[static_cast<size_t>(i)] =
        0.5f * static_cast<float>(std::sin(phase));
  }
  return w;
}

/* ================================ CLI ===================================== */

static void usage() {
  std::printf(
      "voicefx_cli — test harness for libvoicefx (ABI v%d)\n\n"
      "  voicefx_cli --list\n"
      "  voicefx_cli --preset <id> [--in in.wav] [--out out.wav]\n"
      "  voicefx_cli --fx <name[:key=val,...]> [--fx ...] \\\n"
      "              [--wet 0..1] [--gain 0..4] [--in in.wav] [--out out.wav]\n\n"
      "Without --in a 3 s sine sweep (48 kHz) is generated.\n"
      "Default output: out.wav (16-bit mono PCM).\n",
      VOICEFX_ABI_VERSION);
}

static void listPresets() {
  std::printf("presets:\n");
  for (const Preset& p : kPresets) std::printf("  %s\n", p.id);
  std::printf("\neffects and params (--fx name:key=val,...):\n");
  for (const FxName& f : kFxNames) {
    std::printf("  %-10s ", f.name);
    bool first = true;
    for (const ParamName& pn : kParamNames) {
      if (pn.type != f.type) continue;
      std::printf("%s%s", first ? "" : ", ", pn.key);
      first = false;
    }
    std::printf("\n");
  }
}

/* Applies one "--fx name:key=val,key=val" spec to the chain. */
static bool addFxSpec(VfxChain* chain, const std::string& spec) {
  const size_t colon = spec.find(':');
  const std::string name = spec.substr(0, colon);
  const int type = fxTypeByName(name.c_str());
  if (type < 0) {
    std::fprintf(stderr, "error: unknown effect '%s'\n", name.c_str());
    return false;
  }
  const int idx = vfx_add(chain, type);
  if (idx < 0) {
    std::fprintf(stderr, "error: vfx_add(%s) failed (chain full?)\n",
                 name.c_str());
    return false;
  }
  if (colon == std::string::npos) return true;

  std::string rest = spec.substr(colon + 1);
  size_t pos = 0;
  while (pos < rest.size()) {
    size_t comma = rest.find(',', pos);
    if (comma == std::string::npos) comma = rest.size();
    const std::string kv = rest.substr(pos, comma - pos);
    pos = comma + 1;
    const size_t eq = kv.find('=');
    if (eq == std::string::npos) {
      std::fprintf(stderr, "error: bad param spec '%s' (want key=val)\n",
                   kv.c_str());
      return false;
    }
    const std::string key = kv.substr(0, eq);
    const int paramId = paramIdByKey(type, key.c_str());
    if (paramId < 0) {
      std::fprintf(stderr, "error: '%s' has no param '%s'\n", name.c_str(),
                   key.c_str());
      return false;
    }
    vfx_set_param(chain, idx, paramId,
                  static_cast<float>(std::atof(kv.c_str() + eq + 1)));
  }
  return true;
}

int main(int argc, char** argv) {
  const char* inPath = nullptr;
  const char* outPath = "out.wav";
  const char* presetId = nullptr;
  std::vector<std::string> fxSpecs;
  float wetMix = 1.0f, outGain = 1.0f;

  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    auto next = [&](const char* opt) -> const char* {
      if (i + 1 >= argc) {
        std::fprintf(stderr, "error: %s needs a value\n", opt);
        std::exit(2);
      }
      return argv[++i];
    };
    if (a == "--list") {
      listPresets();
      return 0;
    } else if (a == "--help" || a == "-h") {
      usage();
      return 0;
    } else if (a == "--in") {
      inPath = next("--in");
    } else if (a == "--out") {
      outPath = next("--out");
    } else if (a == "--preset") {
      presetId = next("--preset");
    } else if (a == "--fx") {
      fxSpecs.push_back(next("--fx"));
    } else if (a == "--wet") {
      wetMix = static_cast<float>(std::atof(next("--wet")));
    } else if (a == "--gain") {
      outGain = static_cast<float>(std::atof(next("--gain")));
    } else {
      std::fprintf(stderr, "error: unknown arg '%s'\n", a.c_str());
      usage();
      return 2;
    }
  }

  /* ABI sanity — same check the Dart loader performs. */
  if (vfx_abi_version() != VOICEFX_ABI_VERSION) {
    std::fprintf(stderr, "error: ABI mismatch (lib=%d, header=%d)\n",
                 vfx_abi_version(), VOICEFX_ABI_VERSION);
    return 1;
  }

  Wav wav;
  if (inPath) {
    if (!readWav(inPath, &wav)) return 1;
    std::printf("input: %s (%d Hz, %zu samples)\n", inPath, wav.sampleRate,
                wav.samples.size());
  } else {
    wav = makeSweep();
    std::printf("input: generated sweep (48000 Hz, %zu samples)\n",
                wav.samples.size());
  }

  /* 10 ms blocks, like the live capture path (480 @ 48 kHz). */
  int block = wav.sampleRate / 100;
  if (block < 1) block = 1;
  VfxChain* chain = vfx_create(wav.sampleRate, block);
  if (!chain) {
    std::fprintf(stderr, "error: vfx_create failed\n");
    return 1;
  }

  if (presetId) {
    const Preset* p = findPreset(presetId);
    if (!p) {
      std::fprintf(stderr, "error: unknown preset '%s' (try --list)\n",
                   presetId);
      vfx_destroy(chain);
      return 1;
    }
    for (int ni = 0; ni < p->nNodes; ++ni) {
      const PNode& nd = p->nodes[ni];
      const int idx = vfx_add(chain, nd.type);
      if (idx < 0) {
        std::fprintf(stderr, "error: vfx_add failed for preset node %d\n", ni);
        vfx_destroy(chain);
        return 1;
      }
      for (int pi = 0; pi < nd.nParams; ++pi) {
        vfx_set_param(chain, idx, nd.params[pi].id, nd.params[pi].value);
      }
    }
    std::printf("chain: preset '%s' (%d nodes)\n", presetId, p->nNodes);
  }
  for (const std::string& spec : fxSpecs) {
    if (!addFxSpec(chain, spec)) {
      vfx_destroy(chain);
      return 1;
    }
  }
  vfx_set_master(chain, wetMix, outGain);

  /* Block-by-block, in-place — exactly how the capture hook will call it. */
  float peak = 0.0f;
  double sumSq = 0.0;
  for (size_t off = 0; off < wav.samples.size();
       off += static_cast<size_t>(block)) {
    int n = static_cast<int>(wav.samples.size() - off);
    if (n > block) n = block;
    float* buf = wav.samples.data() + off;
    vfx_process(chain, buf, buf, n);
    for (int i = 0; i < n; ++i) {
      const float v = buf[i];
      if (!(v >= -1.0001f && v <= 1.0001f)) { /* also catches NaN */
        std::fprintf(stderr,
                     "error: sample %zu out of range or NaN (%f)\n",
                     off + static_cast<size_t>(i), static_cast<double>(v));
        vfx_destroy(chain);
        return 1;
      }
      const float a = std::fabs(v);
      if (a > peak) peak = a;
      sumSq += static_cast<double>(v) * static_cast<double>(v);
    }
  }
  vfx_destroy(chain);

  const double rms =
      wav.samples.empty()
          ? 0.0
          : std::sqrt(sumSq / static_cast<double>(wav.samples.size()));
  std::printf("processed: peak=%.3f rms=%.4f\n", static_cast<double>(peak),
              rms);

  if (!writeWav(outPath, wav)) return 1;
  std::printf("output: %s\n", outPath);
  return 0;
}
