import 'dart:math' as math;
import 'dart:typed_data';

/// Voice-note waveforms (batch 5): the recorder samples the microphone level
/// ~10× a second; the message carries at most 64 bytes, one 0–255 level per
/// slot, so a 5-minute note still fits.
class Waveform {
  Waveform._();

  static const int slots = 64;

  /// [levels] are 0.0–1.0 amplitudes in capture order. Each output slot is
  /// the peak of its share of the input (peaks keep speech visible; averages
  /// flatten it). Fewer than [slots] samples are spread, not padded.
  static Uint8List encode(List<double> levels, {int slots = slots}) {
    final out = Uint8List(slots);
    if (levels.isEmpty) return out;
    if (levels.length <= slots) {
      for (var i = 0; i < slots; i++) {
        final src = (i * levels.length / slots).floor().clamp(0, levels.length - 1);
        out[i] = _byte(levels[src]);
      }
      return out;
    }
    for (var i = 0; i < slots; i++) {
      final start = (i * levels.length / slots).floor();
      final end = math.max(start + 1, ((i + 1) * levels.length / slots).floor());
      var peak = 0.0;
      for (var k = start; k < end && k < levels.length; k++) {
        peak = math.max(peak, levels[k]);
      }
      out[i] = _byte(peak);
    }
    return out;
  }

  static int _byte(double v) => (v.clamp(0.0, 1.0) * 255).round();

  /// Bars (0.0–1.0) for rendering: the stored bytes resampled to [bars]
  /// slots, with a floor so silence still draws a hairline. Null / empty
  /// input yields a flat, deterministic placeholder seeded by [seed] so a
  /// legacy note (no waveform) looks like a voice note rather than a ruler.
  static List<double> bars(Uint8List? data, {int bars = 40, String seed = ''}) {
    if (data == null || data.isEmpty) {
      final rnd = math.Random(seed.hashCode);
      return [for (var i = 0; i < bars; i++) 0.2 + rnd.nextDouble() * 0.5];
    }
    // Normalise against the loudest slot so a quiet note still fills the bar.
    var maxV = 1;
    for (final b in data) {
      if (b > maxV) maxV = b;
    }
    return [
      for (var i = 0; i < bars; i++)
        (data[(i * data.length / bars).floor().clamp(0, data.length - 1)] / maxV)
            .clamp(0.08, 1.0),
    ];
  }

  /// Microphone dBFS (record's `Amplitude.current`, −160…0) → 0.0–1.0.
  static double fromDb(double db) => ((db + 60) / 60).clamp(0.0, 1.0);
}
