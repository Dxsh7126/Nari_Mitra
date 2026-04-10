import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'mfcc_extractor.dart';

class AudioModel {
  late Interpreter _interpreter;

  /// Minimum RMS level to proceed with inference.
  /// Below this = silence → return isSilent:true without running the model.
  static const double _minRmsEnergy = 0.01;

  /// ZCR bounds for speech-like audio.
  /// < _minZcr  → pure hum / DC offset / silence (not speech)
  /// > _maxZcr  → broadband noise / hiss (not speech)
  static const double _minZcr = 0.005;
  static const double _maxZcr  = 0.45;

  /// Load the TFLite model from assets. Must be called once before predicting.
  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/aggression_model.tflite',
        options: InterpreterOptions()..threads = 2,
      );
    } catch (e) {
      rethrow;
    }
  }

  // ─── Single Window Inference ────────────────────────────────────────────────

  /// Run inference on a single 1-second WAV clip.
  ///
  /// Applies RMS silence gate AND ZCR speech gate before the model.
  /// Returns a [PredictionResult] with the score and metadata.
  Future<PredictionResult> predictFromWavBytes(Uint8List wavBytes) async {
    final double rms = MFCCExtractor.computeRms(wavBytes);
    final double zcr = MFCCExtractor.computeZcr(wavBytes);

    // Silence gate
    if (rms < _minRmsEnergy) {
      return PredictionResult(
          score: 0.0, isSilent: true, rms: rms, zcr: zcr);
    }

    // ZCR gate — skip inference if the audio clearly isn't speech
    if (zcr < _minZcr || zcr > _maxZcr) {
      return PredictionResult(
          score: 0.0, isSilent: true, rms: rms, zcr: zcr);
    }

    final double score = await _runModel(wavBytes);
    return PredictionResult(score: score, isSilent: false, rms: rms, zcr: zcr);
  }

  // ─── Multi-Window (Temporal Voting) Inference ───────────────────────────────

  /// Run inference on a list of 1-second WAV windows (each a full WAV with header).
  ///
  /// Returns a [MultiWindowResult] with per-window [PredictionResult]s.
  /// The [isAggressive] flag is true only if at least [minVotes] out of the
  /// total windows are scored as aggressive (score > [threshold]).
  Future<MultiWindowResult> predictMultiWindow(
    List<Uint8List> windows, {
    double threshold = 0.75,
    int minVotes = 2,
  }) async {
    final List<PredictionResult> results = [];
    for (final window in windows) {
      results.add(await predictFromWavBytes(window));
    }

    final int aggressiveVotes = results
        .where((r) => !r.isSilent && r.score > threshold)
        .length;
    final int nonSilentCount = results.where((r) => !r.isSilent).length;

    // If all windows are silent, treat as silent overall
    if (nonSilentCount == 0) {
      return MultiWindowResult(
        windowResults: results,
        isAggressive: false,
        isTotalSilent: true,
      );
    }

    return MultiWindowResult(
      windowResults: results,
      isAggressive: aggressiveVotes >= minVotes,
      isTotalSilent: false,
    );
  }

  // ─── Shared Model Runner ────────────────────────────────────────────────────

  Future<double> _runModel(Uint8List wavBytes) async {
    final List<List<double>> mfcc = MFCCExtractor.extractFromWavBytes(wavBytes);

    // DEBUG: print MFCC stats for comparison with librosa
    double globalSum = 0, globalSumSq = 0, count = 0;
    for (final frame in mfcc) {
      for (final v in frame) {
        globalSum += v;
        globalSumSq += v * v;
        count++;
      }
    }
    final mean = globalSum / count;
    final std = (globalSumSq / count - mean * mean);
    // ignore: avoid_print
    print('DART MFCC (normalized): mean=${mean.toStringAsFixed(4)} '
        'std=${std.toStringAsFixed(4)} '
        'f0c0=${mfcc[0][0].toStringAsFixed(4)} '
        'f0c1=${mfcc[0][1].toStringAsFixed(4)} '
        'f0c2=${mfcc[0][2].toStringAsFixed(4)}');

    final input = [mfcc];
    var output = [[0.0]];
    _interpreter.run(input, output);
    return output[0][0];
  }

  // ─── Verification (JSON Asset) ──────────────────────────────────────────────

  /// Prediction from a pre-computed MFCC JSON asset (for verification testing).
  Future<double> predictFromAsset(String fileName) async {
    final String jsonString = await rootBundle.loadString('assets/$fileName');
    final List<dynamic> jsonData = json.decode(jsonString);
    final List<double> flattened =
        jsonData.expand((row) => List<double>.from(row)).toList();

    final input = [
      List.generate(32, (i) => flattened.sublist(i * 40, (i + 1) * 40))
    ];
    var output = [[0.0]];

    _interpreter.run(input, output);
    return output[0][0];
  }
}

// ─── Result Types ─────────────────────────────────────────────────────────────

/// Result of a single-window prediction.
class PredictionResult {
  final double score;
  final bool isSilent;
  final double rms;
  final double zcr;

  const PredictionResult({
    required this.score,
    required this.isSilent,
    required this.rms,
    required this.zcr,
  });
}

/// Result of a multi-window (temporal voting) prediction.
class MultiWindowResult {
  final List<PredictionResult> windowResults;
  final bool isAggressive;
  final bool isTotalSilent;

  const MultiWindowResult({
    required this.windowResults,
    required this.isAggressive,
    required this.isTotalSilent,
  });

  int get windowCount => windowResults.length;

  int get aggressiveVoteCount =>
      windowResults.where((r) => !r.isSilent && r.score > 0.5).length;

  double get averageRms {
    if (windowResults.isEmpty) return 0.0;
    return windowResults.map((r) => r.rms).reduce((a, b) => a + b) /
        windowResults.length;
  }

  double get averageZcr {
    if (windowResults.isEmpty) return 0.0;
    return windowResults.map((r) => r.zcr).reduce((a, b) => a + b) /
        windowResults.length;
  }
}