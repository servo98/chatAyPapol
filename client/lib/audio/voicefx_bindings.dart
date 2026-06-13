// voicefx_bindings.dart — FFI crudo hacia la lib nativa VoiceFX.
//
// Espejo 1:1 de native/voicefx/include/voicefx.h (ABI v1). NO usar directo
// desde UI: la capa pública es VoiceFxEngine (voice_fx.dart). Este archivo
// solo resuelve la dynlib, valida la ABI y envuelve los símbolos C.
//
// Carga: voicefx.dll (Windows) / libvoicefx.so (Linux). Orden de búsqueda:
//   1. ruta explícita en la env var VOICEFX_LIB (útil para el harness CLI)
//   2. nombre pelado (resuelve junto al ejecutable / loader del SO)
//   3. junto a Platform.resolvedExecutable (donde el packaging copia el binario)
//   4. <exe>/lib/ (layout del bundle Linux de Flutter)
//   5. build local de desarrollo bajo client/native/voicefx/build/
// Si nada carga o vfx_abi_version() != 1 → open() devuelve null y el engine
// queda en modo no-op (el cliente funciona sin FX).

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Versión de ABI que estos bindings entienden (VOICEFX_ABI_VERSION).
const int kVoicefxAbiVersion = 3;

/// Máximo de nodos por cadena (VFX_MAX_NODES).
const int kVfxMaxNodes = 16;

/// Handle opaco: `typedef struct VfxChain VfxChain;`
final class VfxChain extends Opaque {}

// ---------------------------------------------------------------------------
// Typedefs C <-> Dart, uno por símbolo exportado.
// ---------------------------------------------------------------------------

// int vfx_abi_version(void);
typedef _VfxAbiVersionC = Int32 Function();
typedef _VfxAbiVersionDart = int Function();

// VfxChain* vfx_create(int sampleRate, int maxFrames);
typedef _VfxCreateC = Pointer<VfxChain> Function(Int32 sampleRate, Int32 maxFrames);
typedef _VfxCreateDart = Pointer<VfxChain> Function(int sampleRate, int maxFrames);

// void vfx_destroy(VfxChain* chain);
typedef _VfxDestroyC = Void Function(Pointer<VfxChain> chain);
typedef _VfxDestroyDart = void Function(Pointer<VfxChain> chain);

// void vfx_clear(VfxChain* chain);
typedef _VfxClearC = Void Function(Pointer<VfxChain> chain);
typedef _VfxClearDart = void Function(Pointer<VfxChain> chain);

// int vfx_add(VfxChain* chain, int effectType);
typedef _VfxAddC = Int32 Function(Pointer<VfxChain> chain, Int32 effectType);
typedef _VfxAddDart = int Function(Pointer<VfxChain> chain, int effectType);

// void vfx_set_param(VfxChain* chain, int nodeIndex, int paramId, float value);
typedef _VfxSetParamC = Void Function(
    Pointer<VfxChain> chain, Int32 nodeIndex, Int32 paramId, Float value);
typedef _VfxSetParamDart = void Function(
    Pointer<VfxChain> chain, int nodeIndex, int paramId, double value);

// void vfx_set_bypass(VfxChain* chain, int nodeIndex, int bypass);
typedef _VfxSetBypassC = Void Function(
    Pointer<VfxChain> chain, Int32 nodeIndex, Int32 bypass);
typedef _VfxSetBypassDart = void Function(
    Pointer<VfxChain> chain, int nodeIndex, int bypass);

// void vfx_set_master(VfxChain* chain, float wetMix, float outGain);
typedef _VfxSetMasterC = Void Function(
    Pointer<VfxChain> chain, Float wetMix, Float outGain);
typedef _VfxSetMasterDart = void Function(
    Pointer<VfxChain> chain, double wetMix, double outGain);

// void vfx_process(VfxChain* chain, const float* in, float* out, int numFrames);
typedef _VfxProcessC = Void Function(
    Pointer<VfxChain> chain, Pointer<Float> input, Pointer<Float> output, Int32 numFrames);
typedef _VfxProcessDart = void Function(
    Pointer<VfxChain> chain, Pointer<Float> input, Pointer<Float> output, int numFrames);

// ---------------------------------------------------------------------------
// Wrapper fino sobre la dynlib + un VfxChain.
// ---------------------------------------------------------------------------

/// Envoltorio del C ABI. Una instancia posee como mucho UN VfxChain nativo y
/// un buffer float32 reutilizable (sin allocs por frame en [process]).
class VoicefxNative {
  VoicefxNative._(
    this._abiVersion,
    this._create,
    this._destroy,
    this._clear,
    this._add,
    this._setParam,
    this._setBypass,
    this._setMaster,
    this._process,
  );

  final _VfxAbiVersionDart _abiVersion;
  final _VfxCreateDart _create;
  final _VfxDestroyDart _destroy;
  final _VfxClearDart _clear;
  final _VfxAddDart _add;
  final _VfxSetParamDart _setParam;
  final _VfxSetBypassDart _setBypass;
  final _VfxSetMasterDart _setMaster;
  final _VfxProcessDart _process;

  Pointer<VfxChain> _chain = nullptr;
  Pointer<Float> _buf = nullptr;
  Float32List _bufView = Float32List(0); // vista Dart sobre _buf, cacheada
  int _maxFrames = 0;

  /// true si hay un VfxChain nativo vivo.
  bool get hasChain => _chain != nullptr;

  /// Nombre de archivo de la dynlib según plataforma.
  static String get libraryFileName =>
      Platform.isWindows ? 'voicefx.dll' : 'libvoicefx.so';

  /// Carga la dynlib y valida la ABI. Devuelve null si no se pudo cargar o si
  /// la versión no coincide (nunca lanza: el caller degrada a no-op).
  static VoicefxNative? open() {
    final lib = _openLibrary();
    if (lib == null) return null;
    try {
      final native = VoicefxNative._(
        lib.lookupFunction<_VfxAbiVersionC, _VfxAbiVersionDart>('vfx_abi_version'),
        lib.lookupFunction<_VfxCreateC, _VfxCreateDart>('vfx_create'),
        lib.lookupFunction<_VfxDestroyC, _VfxDestroyDart>('vfx_destroy'),
        lib.lookupFunction<_VfxClearC, _VfxClearDart>('vfx_clear'),
        lib.lookupFunction<_VfxAddC, _VfxAddDart>('vfx_add'),
        lib.lookupFunction<_VfxSetParamC, _VfxSetParamDart>('vfx_set_param'),
        lib.lookupFunction<_VfxSetBypassC, _VfxSetBypassDart>('vfx_set_bypass'),
        lib.lookupFunction<_VfxSetMasterC, _VfxSetMasterDart>('vfx_set_master'),
        lib.lookupFunction<_VfxProcessC, _VfxProcessDart>('vfx_process'),
      );
      final v = native._abiVersion();
      if (v != kVoicefxAbiVersion) {
        debugPrint('[voicefx] ABI mismatch: binario=$v esperado=$kVoicefxAbiVersion');
        return null;
      }
      return native;
    } catch (e) {
      debugPrint('[voicefx] símbolos no resueltos: $e');
      return null;
    }
  }

  static DynamicLibrary? _openLibrary() {
    final name = libraryFileName;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final candidates = <String>[
      // 1. override explícito (harness / desarrollo)
      if (Platform.environment['VOICEFX_LIB']?.isNotEmpty ?? false)
        Platform.environment['VOICEFX_LIB']!,
      // 2. que resuelva el loader del SO
      name,
      // 3. junto al ejecutable (donde el packaging copia el binario)
      '$exeDir$sep$name',
      // 4. layout del bundle Linux (lib/ junto al exe)
      '$exeDir${sep}lib$sep$name',
      // 5. builds locales de desarrollo (client/native/voicefx/build)
      'native${sep}voicefx${sep}build$sep$name',
      'native${sep}voicefx${sep}build${sep}Release$sep$name',
      'client${sep}native${sep}voicefx${sep}build$sep$name',
      'client${sep}native${sep}voicefx${sep}build${sep}Release$sep$name',
    ];
    for (final path in candidates) {
      try {
        return DynamicLibrary.open(path);
      } catch (_) {
        // siguiente candidato
      }
    }
    debugPrint('[voicefx] $name no encontrado; FX deshabilitados');
    return null;
  }

  // -- lifecycle --------------------------------------------------------------

  /// vfx_create. Pre-aloca también el buffer de frames reutilizable.
  /// Devuelve false si el nativo devolvió NULL.
  bool create(int sampleRate, int maxFrames) {
    destroy(); // idempotente: suelta chain/buffer previos si los hubiera
    final chain = _create(sampleRate, maxFrames);
    if (chain == nullptr) return false;
    _chain = chain;
    _maxFrames = maxFrames;
    _buf = calloc<Float>(maxFrames);
    _bufView = _buf.asTypedList(maxFrames);
    return true;
  }

  /// vfx_destroy + libera el buffer. Seguro de llamar sin chain.
  void destroy() {
    if (_chain != nullptr) {
      _destroy(_chain);
      _chain = nullptr;
    }
    if (_buf != nullptr) {
      calloc.free(_buf);
      _buf = nullptr;
      _bufView = Float32List(0);
    }
    _maxFrames = 0;
  }

  // -- edición de cadena (hilo de control) -------------------------------------

  /// vfx_clear (mantiene master).
  void clear() {
    if (_chain != nullptr) _clear(_chain);
  }

  /// vfx_add → índice 0-based del nodo, o -1 (tipo desconocido / cadena llena).
  int add(int effectType) {
    if (_chain == nullptr) return -1;
    return _add(_chain, effectType);
  }

  /// vfx_set_param (el nativo clampea; ids inválidos se ignoran).
  void setParam(int nodeIndex, int paramId, double value) {
    if (_chain != nullptr) _setParam(_chain, nodeIndex, paramId, value);
  }

  /// vfx_set_bypass.
  void setBypass(int nodeIndex, bool bypass) {
    if (_chain != nullptr) _setBypass(_chain, nodeIndex, bypass ? 1 : 0);
  }

  /// vfx_set_master (wetMix 0..1, outGain 0..4; el nativo clampea).
  void setMaster(double wetMix, double outGain) {
    if (_chain != nullptr) _setMaster(_chain, wetMix, outGain);
  }

  // -- procesado (lo llama el bridge de captura / harness) ---------------------

  /// vfx_process IN-PLACE sobre [inOut] (mono float32, [-1,1]).
  /// Copia al buffer nativo pre-alocado, procesa (in == out) y copia de
  /// vuelta. Sin allocs por llamada. Frames > maxFrames se ignoran (no-op)
  /// para no violar el contrato del nativo.
  void process(Float32List inOut) {
    final n = inOut.length;
    if (_chain == nullptr || n == 0 || n > _maxFrames) return;
    _bufView.setRange(0, n, inOut);
    _process(_chain, _buf, _buf, n);
    inOut.setRange(0, n, _bufView);
  }
}
