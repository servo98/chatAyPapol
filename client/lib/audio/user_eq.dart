/// Ajuste de EQ por usuario: graves/medios/agudos + preset.
/// Solo el dueño lo oye; SOLO afecta al audio de un participante concreto.
/// Cuando [isFlat] el nativo NO instala ningún sink (playout WebRTC intacto).
class UserEqSettings {
  final double bass;    // -12..+12 dB
  final double mid;     // -12..+12 dB
  final double treble;  // -12..+12 dB
  final String? preset; // 'plano'|'voz'|'calido'|'radio'|null

  const UserEqSettings({
    this.bass = 0,
    this.mid = 0,
    this.treble = 0,
    this.preset,
  });

  /// true cuando la curva es plana (sin EQ activo). Umbral de 0.1 dB para
  /// absorber imprecisiones de serialización JSON.
  bool get isFlat =>
      bass.abs() < 0.1 && mid.abs() < 0.1 && treble.abs() < 0.1;

  Map<String, dynamic> toJson() => {
        'b': bass,
        'm': mid,
        't': treble,
        if (preset != null) 'p': preset,
      };

  factory UserEqSettings.fromJson(Map<dynamic, dynamic> j) => UserEqSettings(
        bass: (j['b'] as num?)?.toDouble() ?? 0,
        mid: (j['m'] as num?)?.toDouble() ?? 0,
        treble: (j['t'] as num?)?.toDouble() ?? 0,
        preset: j['p'] as String?,
      );

  UserEqSettings copyWith({
    double? bass,
    double? mid,
    double? treble,
    String? preset,
    bool clearPreset = false,
  }) =>
      UserEqSettings(
        bass: bass ?? this.bass,
        mid: mid ?? this.mid,
        treble: treble ?? this.treble,
        preset: clearPreset ? null : (preset ?? this.preset),
      );

  @override
  String toString() =>
      'UserEqSettings(bass=$bass, mid=$mid, treble=$treble, preset=$preset)';
}

/// Presets listos para usar.
///
/// "Plano" y "Voz clara" vienen del mockup HTML (valores confirmados).
/// "Cálido" y "Radio" son propuesta del blueprint — CONFIRMAR DE OÍDO.
const kEqPresets = <String, UserEqSettings>{
  'plano': UserEqSettings(bass: 0, mid: 0, treble: 0, preset: 'plano'),
  'voz': UserEqSettings(bass: -3, mid: 1, treble: 5, preset: 'voz'),
  'calido': UserEqSettings(bass: 4, mid: 1, treble: -2, preset: 'calido'), // INCIERTO: confirmar de oído
  'radio': UserEqSettings(bass: 2, mid: 3, treble: 2, preset: 'radio'),    // INCIERTO: confirmar de oído
};

/// Etiquetas para mostrar en la UI (mismo orden que kEqPresets).
const kEqPresetLabels = <String, String>{
  'plano': 'Plano',
  'voz': 'Voz clara',
  'calido': 'Cálido',
  'radio': 'Radio',
};
