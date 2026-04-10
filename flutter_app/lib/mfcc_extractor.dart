import 'dart:math' as math;
import 'dart:typed_data';
import 'package:fftea/fftea.dart';

/// MFCCExtractor replicates librosa.feature.mfcc() exactly in Dart.
///
/// librosa call used during training:
///   librosa.feature.mfcc(y=audio, sr=16000, n_mfcc=40)
///
/// Exact librosa defaults replicated here:
///   n_fft       = 2048   → FFT size & window length
///   hop_length  = 512    → stride between frames
///   n_mels      = 128    → Mel filterbank bands
///   n_mfcc      = 40     → DCT coefficients to keep
///   fmin        = 0.0
///   fmax        = sr/2   = 8000 Hz
///   htk         = False  → Slaney mel scale (LIBROSA DEFAULT — not HTK)
///   window      = 'hann' → PERIODIC Hann window (librosa/scipy default)
///   center      = True   → zero-pad n_fft//2 on each side
///
/// With these params for 16000 samples:
///   padded length = 16000 + 1024 + 1024 = 18048
///   frames = 1 + (18048 − 2048) / 512 = 32 ✓
class MFCCExtractor {
  static const int _sampleRate = 16000;
  static const int _numSamples = 16000;
  static const int _nFft = 2048;
  static const int _hopLength = 512;
  static const int _nMels = 128;
  static const int _nMfcc = 40;
  static const int _numFrames = 32;

  // From Python training notebook (np.mean / np.std of X_train before norm)
  static const double _trainMean = -19.785846710205078;
  static const double _trainStd  = 145.11888122558594;

  // Slaney mel scale constants
  static const double _minLogHz  = 1000.0;
  //   = 1.8562979... / 27 = 0.06875177...
  static const double _linLow    = 0.0;
  static const double _linStep   = 200.0 / 3.0; // ≈ 66.667 Hz/mel

  // Cached filter bank (built once, reused every call)
  static List<List<double>>? _melFilterbank;

  // ─── Public API ────────────────────────────────────────────────────────────

  /// WAV bytes (PCM16, 16 kHz, mono) → normalized [32 × 40] MFCC matrix.
  static List<List<double>> extractFromWavBytes(Uint8List wavBytes) {
    final signal        = _parseWav(wavBytes);
    final clipped       = _trimOrPad(signal, _numSamples);
    final centered      = _centerPad(clipped, _nFft ~/ 2);
    final powerSpec     = _stft(centered);          // [32][1025]
    final melSpec       = _applyMelFilterbank(powerSpec); // [32][128]
    final logMelSpec    = _logCompress(melSpec);    // [32][128]
    final mfccMatrix    = _dct(logMelSpec);         // [32][40]
    _normalize(mfccMatrix);
    return mfccMatrix;
  }

  /// RMS energy of the WAV audio. Used as silence gate before inference.
  static double computeRms(Uint8List wavBytes) {
    final signal = _parseWav(wavBytes);
    if (signal.isEmpty) return 0.0;
    double sumSq = 0.0;
    for (final s in signal) {
      sumSq += s * s;
    }
    return math.sqrt(sumSq / signal.length);
  }

  /// Zero Crossing Rate of the WAV audio.
  ///
  /// ZCR = number of sign changes / (N − 1).
  /// Calm speech ≈ 0.02–0.15; broadband noise > 0.40.
  /// Used as a secondary gate: if ZCR is way too low (hum/silence) or
  /// way too high (white noise), the audio is not speech at all.
  static double computeZcr(Uint8List wavBytes) {
    final signal = _parseWav(wavBytes);
    if (signal.length < 2) return 0.0;
    int crossings = 0;
    for (int i = 1; i < signal.length; i++) {
      if ((signal[i] >= 0) != (signal[i - 1] >= 0)) {
        crossings++;
      }
    }
    return crossings / (signal.length - 1);
  }

  // ─── WAV parser ────────────────────────────────────────────────────────────

  static List<double> _parseWav(Uint8List bytes) {
    int dataOffset = 44;
    for (int i = 12; i < bytes.length - 8; i++) {
      if (bytes[i]   == 0x64 && bytes[i+1] == 0x61 &&
          bytes[i+2] == 0x74 && bytes[i+3] == 0x61) {
        dataOffset = i + 8;
        break;
      }
    }
    final bd    = ByteData.sublistView(bytes, dataOffset);
    final count = bd.lengthInBytes ~/ 2;
    return List<double>.generate(
      count,
      (i) => bd.getInt16(i * 2, Endian.little) / 32768.0,
    );
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  static List<double> _trimOrPad(List<double> s, int n) {
    if (s.length >= n) return s.sublist(0, n);
    final out = List<double>.filled(n, 0.0);
    for (int i = 0; i < s.length; i++) {
      out[i] = s[i];
    }
    return out;
  }

  static List<double> _centerPad(List<double> s, int pad) {
    final out = List<double>.filled(s.length + 2 * pad, 0.0);
    for (int i = 0; i < s.length; i++) {
      out[i + pad] = s[i];
    }
    return out;
  }

  // ─── STFT → power spectrogram  [numFrames][nFft/2+1] ─────────────────────

  static List<List<double>> _stft(List<double> sig) {
    // PERIODIC Hann window: w[n] = 0.5*(1 − cos(2π·n/N))
    // (librosa / scipy use periodic=True which divides by N not N-1)
    final hann = List<double>.generate(
      _nFft,
      (n) => 0.5 * (1.0 - math.cos(2.0 * math.pi * n / _nFft)),
    );

    final fft       = FFT(_nFft);
    const specBins  = _nFft ~/ 2 + 1; // 1025
    final numFrames = 1 + (sig.length - _nFft) ~/ _hopLength;

    final ps = List.generate(numFrames, (_) => List<double>.filled(specBins, 0.0));

    for (int f = 0; f < numFrames; f++) {
      final frame = Float64List(_nFft);
      final start = f * _hopLength;
      for (int n = 0; n < _nFft; n++) {
        frame[n] = sig[start + n] * hann[n];
      }
      final spec = fft.realFft(frame);
      for (int k = 0; k < specBins; k++) {
        final re = spec[k].x;
        final im = spec[k].y;
        ps[f][k] = re * re + im * im;
      }
    }

    return _padOrTrimFrames(ps, _numFrames, specBins);
  }

  static List<List<double>> _padOrTrimFrames(
      List<List<double>> frames, int target, int bins) {
    if (frames.length == target) return frames;
    if (frames.length > target)  return frames.sublist(0, target);
    final out = List<List<double>>.from(frames);
    while (out.length < target) {
      out.add(List<double>.filled(bins, 0.0));
    }
    return out;
  }

  // ─── Slaney mel scale (librosa default, htk=False) ─────────────────────────
  //
  // Linear below 1000 Hz:  mel = (hz − 0) / (200/3)
  // Log    at/above 1000:  mel = min_log_mel + ln(hz / 1000) / logStep
  //   where logStep = ln(6.4) / 27 ≈ 0.068751...
  //   and   min_log_mel = (1000 − 0) / (200/3) = 15.0

  static const double _minLogMel = _minLogHz / _linStep; // = 15.0

  static double _hzToMelSlaney(double hz) {
    if (hz < _minLogHz) {
      return (hz - _linLow) / _linStep;
    } else {
      return _minLogMel + math.log(hz / _minLogHz) / _logStepVal;
    }
  }

  // ln(6.4)/27  (computed as a runtime constant from math.log)
  static final double _logStepVal = math.log(6.4) / 27.0;

  static double _melToHzSlaney(double mel) {
    if (mel < _minLogMel) {
      return _linLow + mel * _linStep;
    } else {
      return _minLogHz * math.exp((mel - _minLogMel) * _logStepVal);
    }
  }

  // ─── Build Mel filterbank [nMels × specBins] ──────────────────────────────
  // Matches librosa.filters.mel(sr, n_fft, n_mels, norm='slaney', htk=False)
  // The 'slaney' norm divides each triangular filter by its bandwidth so that
  // all filters have equal area (unit area). This is the librosa default.

  static List<List<double>> _buildMelFilterbank() {
    const int specBins = _nFft ~/ 2 + 1; // 1025
    const double fmax  = _sampleRate / 2.0; // 8000 Hz

    final double melMin = _hzToMelSlaney(0.0);
    final double melMax = _hzToMelSlaney(fmax);

    // _nMels+2 equally spaced Mel points (Slaney scale)
    final int nPts = _nMels + 2;
    final mels = List<double>.generate(
      nPts,
      (i) => melMin + (melMax - melMin) * i / (nPts - 1),
    );
    final hz = mels.map(_melToHzSlaney).toList();

    // Map Hz → FFT bin index  (librosa uses floor on (nFft+1)*f/sr)
    final bins = hz.map((f) => (f * (_nFft + 1) / _sampleRate).floor()).toList();

    // Build normalized triangular filters
    // enorm[m] = 2 / (hz[m+1] - hz[m-1])  — slaney area normalization
    final fb = List.generate(_nMels, (_) => List<double>.filled(specBins, 0.0));
    for (int m = 1; m <= _nMels; m++) {
      final int lo  = bins[m - 1];
      final int ctr = bins[m];
      final int hi  = bins[m + 1];

      // Rising slope
      for (int k = lo; k < ctr && k < specBins; k++) {
        if (ctr > lo) fb[m-1][k] = (k - lo) / (ctr - lo);
      }
      // Falling slope
      for (int k = ctr; k < hi && k < specBins; k++) {
        if (hi > ctr) fb[m-1][k] = (hi - k) / (hi - ctr);
      }

      // Apply slaney bandwidth normalization:
      // enorm = 2.0 / (hz_right - hz_left)
      final double bandwidth = hz[m + 1] - hz[m - 1];
      if (bandwidth > 0) {
        final double enorm = 2.0 / bandwidth;
        for (int k = 0; k < specBins; k++) {
          fb[m-1][k] *= enorm;
        }
      }
    }
    return fb;
  }


  // ─── Apply filterbank  [frames][nMels] ────────────────────────────────────

  static List<List<double>> _applyMelFilterbank(List<List<double>> ps) {
    _melFilterbank ??= _buildMelFilterbank();
    final fb = _melFilterbank!;
    const specBins = _nFft ~/ 2 + 1;
    return List.generate(ps.length, (f) {
      return List<double>.generate(_nMels, (m) {
        double s = 0.0;
        for (int k = 0; k < specBins; k++) {
          s += fb[m][k] * ps[f][k];
        }
        return s;
      });
    });
  }

  // ─── Log compression ───────────────────────────────────────────────────────

  static List<List<double>> _logCompress(List<List<double>> mel) {
    return List.generate(mel.length, (f) {
      return List<double>.generate(_nMels, (m) {
        final v = mel[f][m];
        return math.log(v < 1e-10 ? 1e-10 : v);
      });
    });
  }

  // ─── Orthonormal DCT-II  [frames][nMfcc] ──────────────────────────────────
  // Matches scipy.fftpack.dct(x, axis=0, type=2, norm='ortho')
  // which librosa applies along the mel axis for each frame.

  static List<List<double>> _dct(List<List<double>> logMel) {
    final nF = logMel.length;
    final res = List.generate(nF, (_) => List<double>.filled(_nMfcc, 0.0));
    for (int f = 0; f < nF; f++) {
      for (int k = 0; k < _nMfcc; k++) {
        double s = 0.0;
        for (int n = 0; n < _nMels; n++) {
          s += logMel[f][n] * math.cos(math.pi * k * (n + 0.5) / _nMels);
        }
        res[f][k] = s * (k == 0
            ? math.sqrt(1.0 / _nMels)
            : math.sqrt(2.0 / _nMels));
      }
    }
    return res;
  }

  // ─── Normalize with training statistics ───────────────────────────────────

  static void _normalize(List<List<double>> m) {
    for (int f = 0; f < m.length; f++) {
      for (int c = 0; c < m[f].length; c++) {
        m[f][c] = (m[f][c] - _trainMean) / (_trainStd + 1e-8);
      }
    }
  }
}
