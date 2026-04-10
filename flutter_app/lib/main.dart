// ============================================================
//  main.dart — Nari Mitra Safety Dashboard
//  v3 — Production Build
//
//  Features:
//    • Pulsing radar animation on the detection button
//    • 10-second vibrating SOS countdown with Cancel
//    • Multi-contact emergency blast (all contacts called simultaneously)
//    • Native contact picker (flutter_contacts) + SharedPrefs storage
//    • Full on-device TFLite inference + temporal voting
//    • Dual-action SOS: Twilio blast + stealth evidence WAV
//    • Evidence Vault: browse & play back all recorded evidence files
// ============================================================

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'audio_model.dart';
import 'sos_service.dart';
import 'package:flutter_sound/flutter_sound.dart' hide PlayerState;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Theme constants
// ─────────────────────────────────────────────────────────────────────────────

const _kBg      = Color(0xFF08081A);
const _kCard    = Color(0xFF12122A);
const _kPrimary = Color(0xFF7C3AED); // deep violet
const _kSafe    = Color(0xFF10B981); // emerald
const _kDanger  = Color(0xFFEF4444); // crimson
const _kAmber   = Color(0xFFF59E0B); // amber (recording)
const _kTextSub = Color(0xFF8888AA);

// ─────────────────────────────────────────────────────────────────────────────
//  Entry point
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const NariMitraApp());
}

class NariMitraApp extends StatelessWidget {
  const NariMitraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Nari Mitra',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _kBg,
        colorScheme: const ColorScheme.dark(
          primary: _kPrimary,
          surface: _kCard,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const SafetyScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SafetyScreen
// ─────────────────────────────────────────────────────────────────────────────

class SafetyScreen extends StatefulWidget {
  const SafetyScreen({super.key});

  @override
  State<SafetyScreen> createState() => _SafetyScreenState();
}

class _SafetyScreenState extends State<SafetyScreen>
    with TickerProviderStateMixin {
  // ── Model & recorder ─────────────────────────────────────────────────────
  final AudioModel _model = AudioModel();
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();

  // ── Backend URL ──────────────────────────────────────────────────────────
  // TODO: Replace this placeholder with your actual Render URL after deploying.
  //       Find it in: Render Dashboard → your service → URL (top of the page).
  //       Format will be: https://<your-service-name>.onrender.com/sos
  static const String _sosBackendUrl = 'https://nari-mitra-backend.onrender.com/sos';

  // ── Tunable threshold ────────────────────────────────────────────────────
  double _threshold = 0.85;

  // ── App state ────────────────────────────────────────────────────────────
  bool _loading      = false;
  bool _modelLoaded  = false;
  bool _isSilent     = false;
  bool _isAggressive = false;
  List<PredictionResult> _windowResults = [];
  String _errorMessage = '';

  // ── Contacts (persisted via SharedPreferences) ───────────────────────────
  // Parallel lists: index N in both = one contact entry.
  List<String> _contactNames  = [];
  List<String> _contactPhones = [];

  // ── Radar pulse animation ────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double> _ring1;
  late Animation<double> _ring2;
  late Animation<double> _ring3;

  // ── SOS countdown (lives inside dialog, tracked here for cancel) ─────────
  Timer? _countdownTimer;

  // ─────────────────────────────────────────────────────────────────────────
  //  Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _initRecorder();
    _initModel();
    _loadContacts();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _countdownTimer?.cancel();
    Vibration.cancel();
    _recorder.closeRecorder();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Initialisation
  // ─────────────────────────────────────────────────────────────────────────

  void _initAnimations() {
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();

    _ring1 = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
          parent: _pulseCtrl,
          curve: const Interval(0.0, 0.85, curve: Curves.easeOut)),
    );
    _ring2 = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
          parent: _pulseCtrl,
          curve: const Interval(0.22, 0.95, curve: Curves.easeOut)),
    );
    _ring3 = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
          parent: _pulseCtrl,
          curve: const Interval(0.44, 1.0, curve: Curves.easeOut)),
    );
  }

  Future<void> _initRecorder() async {
    await Permission.microphone.request();
    await _recorder.openRecorder();
  }

  Future<void> _initModel() async {
    try {
      await _model.loadModel();
      if (!mounted) return;
      setState(() => _modelLoaded = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Model load failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Contact management
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadContacts() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _contactNames  = prefs.getStringList('ns_contact_names')  ?? [];
      _contactPhones = prefs.getStringList('ns_contact_phones') ?? [];
    });
  }

  Future<void> _saveContacts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('ns_contact_names',  _contactNames);
    await prefs.setStringList('ns_contact_phones', _contactPhones);
  }

  Future<void> _pickContact() async {
    if (_contactNames.length >= 3) {
      _showSnack('Maximum 3 trusted contacts allowed.', _kAmber);
      return;
    }
    final granted = await FlutterContacts.requestPermission(readonly: true);
    if (!granted) {
      _showSnack('Contacts permission denied.', _kDanger);
      return;
    }
    final Contact? picked = await FlutterContacts.openExternalPick();
    if (picked == null) return;
    final Contact? full = await FlutterContacts.getContact(
        picked.id, withProperties: true);
    if (full == null || full.phones.isEmpty) {
      _showSnack('Selected contact has no phone number.', _kAmber);
      return;
    }
    final String phone =
        full.phones.first.number.replaceAll(RegExp(r'\s+'), '');
    setState(() {
      _contactNames.add(full.displayName);
      _contactPhones.add(phone);
    });
    await _saveContacts();
    _showSnack('✓ ${full.displayName} added as trusted contact.', _kSafe);
  }

  Future<void> _removeContact(int index) async {
    setState(() {
      _contactNames.removeAt(index);
      _contactPhones.removeAt(index);
    });
    await _saveContacts();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Live detection
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _runLiveDetection() async {
    setState(() {
      _loading       = true;
      _errorMessage  = '';
      _isSilent      = false;
      _isAggressive  = false;
      _windowResults = [];
    });

    _pulseCtrl.duration = const Duration(milliseconds: 900);
    _pulseCtrl.repeat();

    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String path = '${tempDir.path}/audio_3s.wav';

      await _recorder.startRecorder(
          toFile: path, codec: Codec.pcm16WAV, sampleRate: 16000);
      await Future.delayed(const Duration(seconds: 3));
      await _recorder.stopRecorder();

      final Uint8List wavBytes = await File(path).readAsBytes();
      final List<Uint8List> windows = _splitWavIntoWindows(wavBytes, 3);

      final MultiWindowResult result = await _model.predictMultiWindow(
          windows, threshold: _threshold, minVotes: 2);

      if (!mounted) return;
      setState(() {
        _isSilent      = result.isTotalSilent;
        _isAggressive  = result.isAggressive;
        _windowResults = result.windowResults;
        _loading       = false;
      });

      _pulseCtrl.duration = const Duration(milliseconds: 2200);
      _pulseCtrl.repeat();

      if (result.isTotalSilent) {
        _showSnack('🔇 Too quiet — no speech detected.', Colors.grey.shade700);
      } else {
        final int votes = result.windowResults
            .where((r) => !r.isSilent && r.score > _threshold)
            .length;

        if (result.isAggressive) {
          _showSosCountdownDialog(
              threatScore: result.averageRms, votes: votes);
        } else {
          _showSnack(
            '✅ Safe  |  $votes/3 flagged  |  '
            'avg RMS ${result.averageRms.toStringAsFixed(3)}',
            _kSafe,
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      _pulseCtrl.duration = const Duration(milliseconds: 2200);
      _pulseCtrl.repeat();
      setState(() {
        _loading      = false;
        _errorMessage = 'Detection error: $e';
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  SOS countdown dialog
  // ─────────────────────────────────────────────────────────────────────────

  void _showSosCountdownDialog({double? threatScore, int? votes}) {
    int countdown = 10;
    bool cancelled = false;

    _startSosVibration();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            _countdownTimer ??=
                Timer.periodic(const Duration(seconds: 1), (t) {
              if (cancelled) {
                t.cancel();
                _countdownTimer = null;
                return;
              }
              countdown--;
              if (countdown <= 0) {
                t.cancel();
                _countdownTimer = null;
                Vibration.cancel();
                if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
                _fireSos(threatScore: threatScore, votes: votes);
              } else {
                Vibration.vibrate(duration: 300);
                if (ctx.mounted) setDialogState(() {});
              }
            });

            return Dialog(
              backgroundColor: _kCard,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: _kDanger, width: 2),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: _kDanger, size: 56),
                    const SizedBox(height: 12),
                    const Text(
                      'AGGRESSION DETECTED',
                      style: TextStyle(
                        color: _kDanger,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('SOS will be triggered in',
                        style: TextStyle(
                            color: Colors.white70, fontSize: 14)),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: 110,
                      height: 110,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircularProgressIndicator(
                            value: countdown / 10.0,
                            strokeWidth: 8,
                            color: _kDanger,
                            backgroundColor: Colors.white12,
                          ),
                          Text(
                            '$countdown',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 42,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      height: 64,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          cancelled = true;
                          _countdownTimer?.cancel();
                          _countdownTimer = null;
                          Vibration.cancel();
                          Navigator.of(dialogCtx).pop();
                          _showSnack(
                              '✅ SOS cancelled — stay safe!', _kSafe);
                        },
                        icon: const Icon(Icons.shield_outlined, size: 28),
                        label: const Text(
                          'I AM SAFE — CANCEL',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kSafe,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      _countdownTimer?.cancel();
      _countdownTimer = null;
      Vibration.cancel();
    });
  }

  Future<void> _startSosVibration() async {
    final bool? hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator != true) return;
    await Vibration.vibrate(
      pattern: [0, 400, 150, 400, 150, 400],
      repeat: 0,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Fire SOS — multi-contact blast
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _fireSos({double? threatScore, int? votes}) async {
    if (_contactPhones.isEmpty) {
      _showSnack(
        '⚠️ No emergency contacts set! Add contacts first.',
        _kDanger,
        duration: 5,
      );
      return;
    }

    // Pass the ENTIRE contacts list — backend calls every number.
    final result = await SosService.trigger(
      recorder: _recorder,
      sosBackendUrl: _sosBackendUrl,
      emergencyContactNumbers: _contactPhones,
      threatScore: threatScore,
      votes: votes,
    );

    if (!mounted) return;

    final int n = _contactPhones.length;
    final msg = result.callInitiated
        ? '📞 SOS blasted to $n contact${n > 1 ? 's' : ''}.'
            '${result.recorderStarted ? ' Evidence recording active.' : ''}'
        : '⚠️ SOS failed: ${result.errorMessage}';

    _showSnack(msg, result.callInitiated ? _kPrimary : _kDanger, duration: 6);
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Evidence Vault navigation
  // ─────────────────────────────────────────────────────────────────────────

  void _openEvidenceVault() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const EvidenceVaultScreen()),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  WAV utilities
  // ─────────────────────────────────────────────────────────────────────────

  List<Uint8List> _splitWavIntoWindows(Uint8List wav, int count) {
    final bd             = ByteData.sublistView(wav);
    final origSampleRate = bd.getUint32(24, Endian.little);
    final origChannels   = bd.getUint16(22, Endian.little);
    final bitsPerSample  = bd.getUint16(34, Endian.little);

    int dataStart = 44;
    for (int i = 12; i < wav.length - 8; i++) {
      if (wav[i] == 0x64 && wav[i + 1] == 0x61 &&
          wav[i + 2] == 0x74 && wav[i + 3] == 0x61) {
        dataStart = i + 8;
        break;
      }
    }

    final Uint8List audioData = wav.sublist(dataStart);
    final int bytesPerSample  = (bitsPerSample / 8).round() * origChannels;
    final int samplesPerWin   = (audioData.length ~/ bytesPerSample) ~/ count;
    final int bytesPerWin     = samplesPerWin * bytesPerSample;

    final List<Uint8List> windows = [];
    for (int w = 0; w < count; w++) {
      final int start = w * bytesPerWin;
      final int end   = (w == count - 1) ? audioData.length : start + bytesPerWin;
      windows.add(_buildWav(
          audioData.sublist(start, end), origSampleRate, origChannels, bitsPerSample));
    }
    return windows;
  }

  Uint8List _buildWav(Uint8List pcm, int sampleRate, int channels, int bits) {
    final int dataLen    = pcm.length;
    final int byteRate   = sampleRate * channels * (bits ~/ 8);
    final int blockAlign = channels * (bits ~/ 8);
    final header         = ByteData(44);

    header.setUint8(0, 0x52); header.setUint8(1, 0x49);
    header.setUint8(2, 0x46); header.setUint8(3, 0x46);
    header.setUint32(4, 36 + dataLen, Endian.little);
    header.setUint8(8, 0x57); header.setUint8(9, 0x41);
    header.setUint8(10, 0x56); header.setUint8(11, 0x45);
    header.setUint8(12, 0x66); header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74); header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1,  Endian.little);
    header.setUint16(22, channels,   Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate,   Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bits,       Endian.little);
    header.setUint8(36, 0x64); header.setUint8(37, 0x61);
    header.setUint8(38, 0x74); header.setUint8(39, 0x61);
    header.setUint32(40, dataLen, Endian.little);

    final out = Uint8List(44 + dataLen);
    out.setRange(0, 44, header.buffer.asUint8List());
    out.setRange(44, 44 + dataLen, pcm);
    return out;
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Utility
  // ─────────────────────────────────────────────────────────────────────────

  void _showSnack(String msg, Color color, {int duration = 3}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.all(12),
      duration: Duration(seconds: duration),
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: _errorMessage.isNotEmpty
            ? _buildError()
            : !_modelLoaded
                ? _buildLoading()
                : _buildDashboard(),
      ),
    );
  }

  Widget _buildError() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: _kDanger, size: 48),
              const SizedBox(height: 16),
              Text(_errorMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _kDanger)),
            ],
          ),
        ),
      );

  Widget _buildLoading() => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: _kPrimary),
            SizedBox(height: 16),
            Text('Loading Nari Mitra…',
                style: TextStyle(color: _kTextSub)),
          ],
        ),
      );

  Widget _buildDashboard() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          const SizedBox(height: 32),
          _buildRadarButton(),
          const SizedBox(height: 24),
          _buildStatusCard(),
          const SizedBox(height: 20),
          if (_windowResults.isNotEmpty) _buildWindowScores(),
          const SizedBox(height: 20),
          _buildThresholdCard(),
          const SizedBox(height: 20),
          _buildEvidenceVaultButton(),
          const SizedBox(height: 20),
          _buildContactsCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader() => Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _kPrimary.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kPrimary.withOpacity(0.3)),
            ),
            child: const Icon(Icons.security, color: _kPrimary, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Nari Mitra',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
                Text('AI Safety Guardian • Edge Inference',
                    style: TextStyle(color: _kTextSub, fontSize: 12)),
              ],
            ),
          ),
          // ── Vault shortcut icon in header ──────────────────────────
          IconButton(
            onPressed: _openEvidenceVault,
            icon: const Icon(Icons.lock_outline_rounded,
                color: _kTextSub, size: 22),
            tooltip: 'Evidence Vault',
          ),
        ],
      );

  // ── Pulsing radar button ──────────────────────────────────────────────────

  Widget _buildRadarButton() {
    final Color ringColor = _loading
        ? _kAmber
        : _isAggressive
            ? _kDanger
            : _windowResults.isNotEmpty && !_isSilent
                ? _kSafe
                : _kPrimary;

    return Center(
      child: AnimatedBuilder(
        animation: _pulseCtrl,
        builder: (_, __) {
          return SizedBox(
            width: 220,
            height: 220,
            child: Stack(
              alignment: Alignment.center,
              children: [
                _buildRing(_ring3.value, ringColor, 105),
                _buildRing(_ring2.value, ringColor, 85),
                _buildRing(_ring1.value, ringColor, 65),
                GestureDetector(
                  onTap: _loading ? null : _runLiveDetection,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: _loading
                            ? [_kAmber, _kAmber.withOpacity(0.6)]
                            : [
                                ringColor.withOpacity(0.9),
                                ringColor.withOpacity(0.4)
                              ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: ringColor.withOpacity(0.45),
                          blurRadius: 30,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: Icon(
                      _loading ? Icons.graphic_eq : Icons.mic_rounded,
                      color: Colors.white,
                      size: 44,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRing(double animValue, Color color, double maxRadius) {
    final double size    = maxRadius * 2 * animValue;
    final double opacity = (1.0 - animValue).clamp(0.0, 1.0) * 0.55;
    return Opacity(
      opacity: opacity,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2.2),
        ),
      ),
    );
  }

  // ── Status card ───────────────────────────────────────────────────────────

  Widget _buildStatusCard() {
    final String label;
    final Color  color;
    final IconData icon;

    if (_loading) {
      label = 'Listening… (3 sec)';
      color = _kAmber;
      icon  = Icons.hearing;
    } else if (_windowResults.isEmpty) {
      label = 'Tap the mic to begin analysis';
      color = _kTextSub;
      icon  = Icons.touch_app_outlined;
    } else if (_isSilent) {
      label = 'Too quiet — no speech detected';
      color = Colors.grey;
      icon  = Icons.volume_off_outlined;
    } else if (_isAggressive) {
      label = '⚠  Aggression Confirmed';
      color = _kDanger;
      icon  = Icons.warning_amber_rounded;
    } else {
      label = '✓  Environment Safe';
      color = _kSafe;
      icon  = Icons.check_circle_outline;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // ── Window scores ─────────────────────────────────────────────────────────

  Widget _buildWindowScores() {
    final double avgRms = _windowResults
            .map((r) => r.rms)
            .reduce((a, b) => a + b) /
        _windowResults.length;
    final double avgZcr = _windowResults
            .map((r) => r.zcr)
            .reduce((a, b) => a + b) /
        _windowResults.length;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Window Analysis  (2/3 majority vote)',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          ...List.generate(_windowResults.length, (i) {
            final r       = _windowResults[i];
            final flagged = !r.isSilent && r.score > _threshold;
            final color   = r.isSilent
                ? Colors.grey
                : flagged ? _kDanger : _kSafe;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text('Win ${i + 1}',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white60)),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: r.isSilent ? 0 : r.score.clamp(0.0, 1.0),
                        minHeight: 10,
                        backgroundColor: Colors.white10,
                        valueColor: AlwaysStoppedAnimation(color),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 80,
                    child: Text(
                      r.isSilent
                          ? '— silent'
                          : '${(r.score * 100).toStringAsFixed(1)}%'
                              '${flagged ? '  ⚑' : ''}',
                      style: TextStyle(
                          fontSize: 12,
                          color: color,
                          fontWeight: flagged
                              ? FontWeight.bold
                              : FontWeight.normal),
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 6),
          Text(
            'avg RMS ${avgRms.toStringAsFixed(4)}   '
            'avg ZCR ${avgZcr.toStringAsFixed(4)}',
            style: const TextStyle(fontSize: 11, color: _kTextSub),
          ),
        ],
      ),
    );
  }

  // ── Threshold slider ──────────────────────────────────────────────────────

  Widget _buildThresholdCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Sensitivity',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _kPrimary.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _threshold.toStringAsFixed(2),
                    style: const TextStyle(
                        color: _kPrimary, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: _kPrimary,
                inactiveTrackColor: Colors.white10,
                thumbColor: _kPrimary,
                overlayColor: _kPrimary.withOpacity(0.2),
              ),
              child: Slider(
                value: _threshold,
                min: 0.3,
                max: 0.95,
                divisions: 13,
                onChanged: (v) => setState(() => _threshold = v),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                Text('More sensitive',
                    style: TextStyle(fontSize: 11, color: _kTextSub)),
                Text('Stricter',
                    style: TextStyle(fontSize: 11, color: _kTextSub)),
              ],
            ),
          ],
        ),
      );

  // ── Evidence Vault button ─────────────────────────────────────────────────

  Widget _buildEvidenceVaultButton() => GestureDetector(
        onTap: _openEvidenceVault,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _kPrimary.withOpacity(0.35)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: _kPrimary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.lock_outline_rounded,
                    color: _kPrimary, size: 22),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Evidence Vault',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    Text('Browse & play stealth SOS recordings',
                        style: TextStyle(color: _kTextSub, fontSize: 11)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: _kTextSub, size: 22),
            ],
          ),
        ),
      );

  // ── Contacts card ─────────────────────────────────────────────────────────

  Widget _buildContactsCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Trusted Contacts',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                if (_contactNames.length < 3)
                  GestureDetector(
                    onTap: _pickContact,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _kPrimary.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: _kPrimary.withOpacity(0.4)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.person_add_outlined,
                              color: _kPrimary, size: 16),
                          SizedBox(width: 6),
                          Text('Add',
                              style: TextStyle(
                                  color: _kPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_contactNames.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: _kTextSub, size: 16),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'No contacts yet. Tap Add to select from address book.',
                        style: TextStyle(color: _kTextSub, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              )
            else
              ...List.generate(_contactNames.length, (i) {
                final isPrimary = i == 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isPrimary
                              ? _kPrimary.withOpacity(0.2)
                              : Colors.white10,
                        ),
                        child: Icon(
                          isPrimary
                              ? Icons.star_rounded
                              : Icons.person_outline,
                          color: isPrimary ? _kPrimary : Colors.white54,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_contactNames[i],
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            Text(_contactPhones[i],
                                style: const TextStyle(
                                    color: _kTextSub, fontSize: 11)),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _removeContact(i),
                        child: const Icon(Icons.close,
                            color: _kTextSub, size: 18),
                      ),
                    ],
                  ),
                );
              }),
            if (_contactNames.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '★ All ${_contactNames.length} '
                  'contact${_contactNames.length > 1 ? 's' : ''} '
                  'will receive the SOS call blast',
                  style: TextStyle(
                      color: _kPrimary.withOpacity(0.7), fontSize: 11),
                ),
              ),
          ],
        ),
      );

  // ── Shared helpers ────────────────────────────────────────────────────────

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: child,
      );
}

// ═════════════════════════════════════════════════════════════════════════════
//  EvidenceVaultScreen
//  Scans the app's documents directory for evidence_*.wav files, displays
//  them sorted newest-first, and allows native playback via audioplayers.
// ═════════════════════════════════════════════════════════════════════════════

class EvidenceVaultScreen extends StatefulWidget {
  const EvidenceVaultScreen({super.key});

  @override
  State<EvidenceVaultScreen> createState() => _EvidenceVaultScreenState();
}

class _EvidenceVaultScreenState extends State<EvidenceVaultScreen> {
  // ── State ────────────────────────────────────────────────────────────────
  List<File> _files        = [];
  bool       _loading      = true;
  String?    _playingPath; // path of currently active file
  PlayerState _playerState = PlayerState.stopped;
  Duration   _position     = Duration.zero;
  Duration   _duration     = Duration.zero;

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription> _subs = [];

  // ─────────────────────────────────────────────────────────────────────────
  //  Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadFiles();
    _subs.addAll([
      _player.onPlayerStateChanged.listen((s) {
        if (mounted) setState(() => _playerState = s);
      }),
      _player.onPositionChanged.listen((p) {
        if (mounted) setState(() => _position = p);
      }),
      _player.onDurationChanged.listen((d) {
        if (mounted) setState(() => _duration = d);
      }),
      _player.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _playingPath = null;
            _position    = Duration.zero;
            _duration    = Duration.zero;
          });
        }
      }),
    ]);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  File loading
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadFiles() async {
    setState(() => _loading = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final all = dir.listSync().whereType<File>().where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('evidence_') && name.endsWith('.wav');
      }).toList();

      // Sort newest first (timestamp is embedded in filename)
      all.sort((a, b) {
        final aName = a.uri.pathSegments.last;
        final bName = b.uri.pathSegments.last;
        return bName.compareTo(aName);
      });

      if (mounted) setState(() { _files = all; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Playback
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _togglePlay(File file) async {
    final path = file.path;

    if (_playingPath == path) {
      // Same file — toggle play/pause
      if (_playerState == PlayerState.playing) {
        await _player.pause();
      } else {
        await _player.resume();
      }
    } else {
      // Different file — stop current, start new
      await _player.stop();
      setState(() {
        _playingPath = path;
        _position    = Duration.zero;
        _duration    = Duration.zero;
      });
      await _player.play(DeviceFileSource(path));
    }
  }

  Future<void> _stopPlayback() async {
    await _player.stop();
    setState(() {
      _playingPath = null;
      _position    = Duration.zero;
      _duration    = Duration.zero;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Deletion
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _deleteFile(File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Recording',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: const Text(
          'This evidence file will be permanently deleted.',
          style: TextStyle(color: _kTextSub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: _kTextSub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete',
                style: TextStyle(color: _kDanger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (_playingPath == file.path) await _stopPlayback();
    await file.delete();
    setState(() => _files.remove(file));
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Extracts the epoch timestamp from the filename and formats it.
  String _formatTimestamp(File file) {
    final name = file.uri.pathSegments.last;           // evidence_1717123456789.wav
    final raw  = name
        .replaceFirst('evidence_', '')
        .replaceAll('.wav', '');
    final ms = int.tryParse(raw);
    if (ms == null) return name;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final pad = (int v) => v.toString().padLeft(2, '0');
    return '${pad(dt.day)}/${pad(dt.month)}/${dt.year}  '
        '${pad(dt.hour)}:${pad(dt.minute)}:${pad(dt.second)}';
  }

  String _formatSize(File file) {
    final bytes = file.lengthSync();
    if (bytes < 1024)        return '${bytes} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kCard,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 20),
          onPressed: () async {
            await _stopPlayback();
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
        title: Row(
          children: [
            const Icon(Icons.lock_outline_rounded,
                color: _kPrimary, size: 20),
            const SizedBox(width: 10),
            const Text('Evidence Vault',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          if (!_loading)
            IconButton(
              icon: const Icon(Icons.refresh_rounded,
                  color: _kTextSub, size: 22),
              onPressed: _loadFiles,
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _kPrimary))
          : _files.isEmpty
              ? _buildEmpty()
              : _buildList(),
    );
  }

  Widget _buildEmpty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open_outlined,
                  color: _kTextSub.withOpacity(0.5), size: 64),
              const SizedBox(height: 20),
              const Text('No recordings yet',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              const Text(
                'Evidence files are created automatically when\nan SOS trigger completes the 10-second countdown.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _kTextSub, fontSize: 13, height: 1.5),
              ),
            ],
          ),
        ),
      );

  Widget _buildList() {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _files.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _buildFileCard(_files[i]),
    );
  }

  Widget _buildFileCard(File file) {
    final isActive  = _playingPath == file.path;
    final isPlaying = isActive && _playerState == PlayerState.playing;
    final isPaused  = isActive && _playerState == PlayerState.paused;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActive
              ? _kPrimary.withOpacity(0.6)
              : Colors.white10,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top row: icon + info + controls ─────────────────────────
          Row(
            children: [
              // Recording icon
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive
                      ? _kPrimary.withOpacity(0.2)
                      : _kDanger.withOpacity(0.12),
                ),
                child: Icon(
                  isActive ? Icons.graphic_eq : Icons.mic_none_rounded,
                  color: isActive ? _kPrimary : _kDanger,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),

              // Timestamp + size
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatTimestamp(file),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatSize(file),
                      style: const TextStyle(
                          color: _kTextSub, fontSize: 11),
                    ),
                  ],
                ),
              ),

              // Play/Pause button
              GestureDetector(
                onTap: () => _togglePlay(file),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kPrimary.withOpacity(0.2),
                  ),
                  child: Icon(
                    isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: _kPrimary,
                    size: 24,
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Delete button
              GestureDetector(
                onTap: () => _deleteFile(file),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _kDanger.withOpacity(0.1),
                  ),
                  child: const Icon(Icons.delete_outline_rounded,
                      color: _kDanger, size: 20),
                ),
              ),
            ],
          ),

          // ── Progress bar (only for the active file) ──────────────────
          if (isActive) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _duration.inMilliseconds > 0
                    ? (_position.inMilliseconds /
                            _duration.inMilliseconds)
                        .clamp(0.0, 1.0)
                    : 0,
                minHeight: 4,
                backgroundColor: Colors.white10,
                valueColor: const AlwaysStoppedAnimation(_kPrimary),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_position),
                  style: const TextStyle(
                      fontSize: 10, color: _kTextSub),
                ),
                Text(
                  _duration > Duration.zero
                      ? _formatDuration(_duration)
                      : '--:--',
                  style: const TextStyle(
                      fontSize: 10, color: _kTextSub),
                ),
              ],
            ),
            if (isPaused)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Paused',
                    style: TextStyle(
                        fontSize: 10,
                        color: _kAmber,
                        fontWeight: FontWeight.w600)),
              ),
          ],
        ],
      ),
    );
  }
}
