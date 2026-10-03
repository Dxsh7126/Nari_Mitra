/// sos_service.dart — Nari Mitra Dual-Action SOS Coordinator
/// ===========================================================
/// When the aggression temporal voting confirms a threat (2/3 windows
/// exceed threshold), this service fires two concurrent actions:
///
///   1. HTTP POST to the Flask /sos backend → Twilio emergency voice calls
///      to ALL contacts in the [emergencyContactNumbers] list simultaneously.
///   2. Silent 30-second stealth microphone recording → evidence_TIMESTAMP.wav
///
/// Both actions start via [SosService.trigger] which returns a [SosResult]
/// describing what succeeded or failed. The stealth recorder runs as a
/// fire-and-forget Future so it does not block the UI or the call dispatch.
///
/// Usage (from main.dart)
/// ----------------------
///   final result = await SosService.trigger(
///     recorder: _recorder,
///     sosBackendUrl: 'http://10.173.5.146:5001/sos',
///     emergencyContactNumbers: _contactPhones,   // full list
///     threatScore: avgScore,
///     votes: aggressiveVoteCount,
///   );
///
/// Dependencies (pubspec.yaml)
/// ---------------------------
///   flutter_sound: ^9.28.0
///   http: ^1.4.0
///   path_provider: ^2.1.5

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_app/models/sos_session.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

// ─── Result types ─────────────────────────────────────────────────────────────

/// Outcome of a single SOS trigger.
class SosResult {
  /// Whether at least one Twilio call was successfully initiated.
  final bool callInitiated;

  /// Number of calls successfully placed.
  final int callCount;

  /// All Twilio Call SIDs returned by the backend.
  final List<String> callSids;

  /// Whether the stealth recorder started successfully.
  final bool recorderStarted;

  /// Absolute path to the evidence WAV file being recorded.
  final String? evidencePath;

  /// Human-readable error message, if any action failed.
  final String? errorMessage;

  const SosResult({
    required this.callInitiated,
    this.callCount = 0,
    this.callSids = const [],
    required this.recorderStarted,
    this.evidencePath,
    this.errorMessage,
  });

  @override
  String toString() =>
      'SosResult(call=$callInitiated count=$callCount sids=$callSids '
      'recorder=$recorderStarted path=$evidencePath err=$errorMessage)';
}

// ─── SosService ──────────────────────────────────────────────────────────────

class SosService {
  /// Duration of the stealth evidence recording.
  static const Duration _evidenceDuration = Duration(seconds: 30);

  /// Sample rate for evidence WAV (matches the detection pipeline).
  static const int _evidenceSampleRate = 16000;

  // ── Dispatch tuning ──────────────────────────────────────────────────────
  // 55 s timeout: long enough to survive a Render cold-start (30–60 s).
  // 1 retry with a 5-second pause handles the rare case where the first
  // attempt catches the server mid-restart and gets a connection refused.
  static const Duration _httpTimeout  = Duration(seconds: 55);
  static const int      _maxAttempts  = 2;
  static const Duration _retryDelay   = Duration(seconds: 5);

  // Private constructor — this is a static utility class.
  SosService._();

  // To get IDs like SOS-1791023456123-483921(change this one security gets implemented)
  static String generateSessionID(){
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(999999);

    return 'SOS-$timestamp-$random';
  }

  // ─── Public API ────────────────────────────────────────────────────────────

  /// Fire the dual-action SOS:
  ///   1. POST to [sosBackendUrl] with the full [emergencyContactNumbers] list
  ///      → backend initiates a separate Twilio call to each number.
  ///   2. Start 30-second stealth evidence recording with [recorder].
  ///
  /// Parameters
  /// ----------
  /// [recorder]
  ///   An already-opened [FlutterSoundRecorder]. The caller owns the lifecycle.
  ///
  /// [sosBackendUrl]
  ///   Full URL of the Flask /sos endpoint.
  ///   e.g. 'http://10.173.5.146:5001/sos'
  ///
  /// [emergencyContactNumbers]
  ///   List of E.164 phone numbers to call simultaneously.
  ///   e.g. ['+919876543210', '+917654321098']
  ///
  /// [threatScore]
  ///   Average aggression metric — logged by the backend for audit.
  ///
  /// [votes]
  ///   Number of 1-second windows that exceeded the threshold (out of 3).
  static Future<SosResult> trigger({
    required FlutterSoundRecorder recorder,
    required String sosBackendUrl,
    SosSession? session,
    List<String> emergencyContactNumbers = const [],
    double? threatScore,
    int? votes,
  }) async {
    // Fire both actions concurrently — do NOT await sequentially.
    final results = await Future.wait([
      _dispatchCallBlast(
        backendUrl: sosBackendUrl,
        contactNumbers: emergencyContactNumbers,
        threatScore: threatScore,
        votes: votes,
        session: session,
      ),
      _startStealthRecorder(recorder),
    ]);

    final callResult     = results[0] as _CallOutcome;
    final recorderResult = results[1] as _RecorderOutcome;

    final errors = <String>[
      if (callResult.error     != null) 'Call: ${callResult.error}',
      if (recorderResult.error != null) 'Recorder: ${recorderResult.error}',
    ];

    return SosResult(
      callInitiated:   callResult.success,
      callCount:       callResult.callSids.length,
      callSids:        callResult.callSids,
      recorderStarted: recorderResult.success,
      evidencePath:    recorderResult.evidencePath,
      errorMessage:    errors.isEmpty ? null : errors.join(' | '),
    );
  }

  // ─── Internal: Twilio blast via backend ───────────────────────────────────

  /// POST the full contacts list to the backend. The Flask server loops
  /// through each number and calls Twilio individually for every contact.
  /// Retries once after [_retryDelay] on timeout or connection failure to
  /// survive a Render free-tier cold-start (30–60 s spin-up delay).
  static Future<_CallOutcome> _dispatchCallBlast({
    required String backendUrl,
    List<String> contactNumbers = const [],
    SosSession? session,
    double? threatScore,
    int? votes,
  }) async {
    final body = <String, dynamic>{

      if (contactNumbers.isNotEmpty) 
        'contacts': contactNumbers,

      if (threatScore != null) 
        'threat_score': threatScore,

      if (votes       != null) 
        'votes': votes,

      if (session != null) ...{
      'session_id':session.sessionId,
      'location':{
        'latitude':session.latitude,
        'longitude':session.longitude,
        'accuracy':session.accuracy,
      },
    },
  };
    final encoded = jsonEncode(body);
    final uri     = Uri.parse(backendUrl);
    final headers = {'Content-Type': 'application/json'};

    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final response = await http
            .post(uri, headers: headers, body: encoded)
            .timeout(_httpTimeout);

        if (response.statusCode == 200) {
          final json    = jsonDecode(response.body) as Map<String, dynamic>;
          final rawSids = json['call_sids'] as List<dynamic>? ?? [];
          final sids    = rawSids.cast<String>();
          return _CallOutcome(success: sids.isNotEmpty, callSids: sids);
        }

        // Non-200: server is up but returned an error — don't retry.
        final msg = 'Backend returned ${response.statusCode}: ${response.body}';
        return _CallOutcome(success: false, error: msg);

      } on TimeoutException {
        if (attempt < _maxAttempts) {
          // Server is cold-starting. Wait briefly then retry.
          await Future.delayed(_retryDelay);
          continue;
        }
        return const _CallOutcome(
          success: false,
          error: 'SOS backend timed out. '
                 'Server may be waking from sleep — try again in 30 s.',
        );

      } on SocketException catch (e) {
        if (attempt < _maxAttempts) {
          await Future.delayed(_retryDelay);
          continue;
        }
        return _CallOutcome(
          success: false,
          error: 'Network error after $attempt attempt(s): $e',
        );

      } catch (e) {
        // Unknown error — no retry benefit.
        return _CallOutcome(success: false, error: e.toString());
      }
    }

    // Unreachable, but satisfies the Dart return requirement.
    return const _CallOutcome(success: false, error: 'Dispatch failed.');
  }

  // ─── Internal: Stealth evidence recorder ──────────────────────────────────

  /// Starts a 30-second stealth background recording.
  /// File saved to: <documentsDir>/evidence_<timestampMs>.wav
  /// Runs silently — no UI changes — so the app does not alert an aggressor.
  static Future<_RecorderOutcome> _startStealthRecorder(
    FlutterSoundRecorder recorder,
  ) async {
    try {
      final dir       = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path      = '${dir.path}/evidence_$timestamp.wav';

      await recorder.startRecorder(
        toFile: path,
        codec: Codec.pcm16WAV,
        sampleRate: _evidenceSampleRate,
        numChannels: 1,
      );

      // Fire-and-forget: does not block the call dispatch or UI.
      unawaited(_waitAndStopRecorder(recorder, _evidenceDuration));

      return _RecorderOutcome(success: true, evidencePath: path);
    } catch (e) {
      return _RecorderOutcome(
        success: false,
        error: 'Recorder failed to start: $e',
      );
    }
  }

  static Future<void> _waitAndStopRecorder(
    FlutterSoundRecorder recorder,
    Duration duration,
  ) async {
    await Future.delayed(duration);
    try {
      if (recorder.isRecording) {
        await recorder.stopRecorder();
      }
    } catch (_) {
      // Ignore stop errors — recorder may have been closed externally.
    }
  }
}

// ─── Private result containers ────────────────────────────────────────────────

class _CallOutcome {
  final bool success;
  final List<String> callSids;
  final String? error;

  const _CallOutcome({
    required this.success,
    this.callSids = const [],
    this.error,
  });
}

class _RecorderOutcome {
  final bool success;
  final String? evidencePath;
  final String? error;

  const _RecorderOutcome({
    required this.success,
    this.evidencePath,
    this.error,
  });
}

/// Silences the "unawaited future" lint for intentional fire-and-forget calls.
void unawaited(Future<void> future) {}
