/// EQ por usuario: 8 bandas de ganancia + preset.
/// Solo el dueño lo oye; SOLO afecta al audio de un participante concreto.
/// Cuando [isFlat] el nativo NO instala ningún sink (playout WebRTC intacto).

/// Frecuencias fijas (Hz) de las 8 bandas. COINCIDEN con kEqFreqs[] del nativo
/// (per_user_eq.cc). El usuario solo ajusta la ganancia dB de cada una.
const kEqFreqs = <double>[60, 120, 250, 500, 1000, 2400, 6000, 12000];
const kEqBands = 8;

/// Etiquetas cortas para la UI (mismo orden que kEqFreqs).
const kEqFreqLabels = <String>['60', '120', '250', '500', '1k', '2.4k', '6k', '12k'];

const _kFlat = <double>[0, 0, 0, 0, 0, 0, 0, 0];

class UserEqSettings {
  /// Ganancia por banda en dB (-12..+12). Longitud = [kEqBands].
  final List<double> gains;
  final String? preset;

  const UserEqSettings({this.gains = _kFlat, this.preset});

  /// true cuando todas las bandas están ~planas (sin EQ activo).
  bool get isFlat => gains.every((g) => g.abs() < 0.1);

  /// Ganancia de la banda [i] (0 si fuera de rango).
  double band(int i) => (i >= 0 && i < gains.length) ? gains[i] : 0.0;

  /// Copia con la banda [i] = [db] (editar a mano borra el preset).
  UserEqSettings withBand(int i, double db) {
    final g = List<double>.filled(kEqBands, 0.0);
    for (var k = 0; k < kEqBands; k++) {
      g[k] = band(k);
    }
    g[i] = db.clamp(-12.0, 12.0);
    return UserEqSettings(gains: g);
  }

  Map<String, dynamic> toJson() => {
        'v': 2,
        'g': gains,
        if (preset != null) 'p': preset,
      };

  /// v2 = lista de ganancias. v1 (viejo) = {b,m,t} de 3 bandas → mapea a las
  /// bandas más cercanas (250/1k/6k = índices 2/4/6).
  factory UserEqSettings.fromJson(Map<dynamic, dynamic> j) {
    if (j['g'] is List) {
      final raw = (j['g'] as List).map((e) => (e as num).toDouble()).toList();
      final g = List<double>.filled(kEqBands, 0.0);
      for (var i = 0; i < kEqBands && i < raw.length; i++) {
        g[i] = raw[i];
      }
      return UserEqSettings(gains: g, preset: j['p'] as String?);
    }
    final g = List<double>.filled(kEqBands, 0.0);
    g[2] = (j['b'] as num?)?.toDouble() ?? 0; // graves → 250 Hz
    g[4] = (j['m'] as num?)?.toDouble() ?? 0; // medios → 1 kHz
    g[6] = (j['t'] as num?)?.toDouble() ?? 0; // agudos → 6 kHz
    return UserEqSettings(gains: g, preset: j['p'] as String?);
  }

  @override
  String toString() => 'UserEqSettings(gains=$gains, preset=$preset)';
}

/// Presets (ganancias dB por banda, 60→12k). "Voz clara" y "Plano" confirmados;
/// el resto son propuesta — afinar de oído.
const kEqPresets = <String, UserEqSettings>{
  'plano': UserEqSettings(gains: [0, 0, 0, 0, 0, 0, 0, 0], preset: 'plano'),
  'voz': UserEqSettings(gains: [-2, -2, -1, 0, 2, 4, 3, 1], preset: 'voz'),
  'calido': UserEqSettings(gains: [3, 2, 1, 0, -1, -2, -2, -1], preset: 'calido'),
  'radio': UserEqSettings(gains: [-6, -3, 0, 3, 4, 2, -4, -8], preset: 'radio'),
  'aire': UserEqSettings(gains: [0, 0, 0, 0, 1, 2, 4, 5], preset: 'aire'),
  'grave': UserEqSettings(gains: [5, 4, 2, 0, 0, 0, -1, -1], preset: 'grave'),
};

/// Etiquetas para la UI (mismo orden que kEqPresets).
const kEqPresetLabels = <String, String>{
  'plano': 'Plano',
  'voz': 'Voz clara',
  'calido': 'Cálido',
  'radio': 'Radio',
  'aire': 'Aire',
  'grave': 'Grave',
};
