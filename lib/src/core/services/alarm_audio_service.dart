import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class AlarmAudioService {
  static final AlarmAudioService _instance = AlarmAudioService._internal();
  factory AlarmAudioService() => _instance;
  AlarmAudioService._internal();

  AudioPlayer? _player;
  bool _isPlaying = false;
  int _activeSessionId = 0;

  bool get isPlaying => _isPlaying;

  /// Initialize the AudioPlayer with STREAM_ALARM audio context
  Future<void> init() async {
    if (_player != null) return;

    final player = AudioPlayer();

    // Android STREAM_ALARM configuration to cut through silent mode
    // and compete with Grab / Shopee alerts.
    final audioContext = AudioContext(
      android: const AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.alarm,
        audioFocus: AndroidAudioFocus.gainTransientExclusive,
      ),
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: const {
          AVAudioSessionOptions.duckOthers,
        },
      ),
    );

    await AudioPlayer.global.setAudioContext(audioContext);
    await player.setAudioContext(audioContext);
    await player.setVolume(1.0);
    _player = player;

    debugPrint('[AlarmAudioService] Initialized with STREAM_ALARM');
  }

  /// Play new order alert sound (orderbaru.mp3) with sequential repeats
  Future<void> playOrderAlarm({int repeat = 3}) async {
    await init();
    await stop();

    final sessionId = ++_activeSessionId;
    _isPlaying = true;

    debugPrint('[AlarmAudioService] Playing order alert (repeats: $repeat, session: $sessionId)');

    try {
      for (int i = 0; i < repeat; i++) {
        if (_activeSessionId != sessionId) break;

        await _player?.stop();
        await _player?.play(AssetSource('sounds/orderbaru.mp3'));

        // Wait for player to finish playing this repetition
        final completer = Completer<void>();
        late final StreamSubscription sub;

        sub = _player!.onPlayerComplete.listen((_) {
          sub.cancel();
          if (!completer.isCompleted) completer.complete();
        });

        // 8-second safety timeout per repetition
        await Future.any([
          completer.future,
          Future.delayed(const Duration(seconds: 8)),
        ]);

        if (i < repeat - 1 && _activeSessionId == sessionId) {
          // 600ms natural breathing gap between repeats
          await Future.delayed(const Duration(milliseconds: 600));
        }
      }
    } catch (e) {
      debugPrint('[AlarmAudioService] Error playing order alarm: $e');
    } finally {
      if (_activeSessionId == sessionId) {
        _isPlaying = false;
      }
    }
  }

  /// Play payment success alert sound (berhasilbayar.mp3)
  Future<void> playPaymentSuccess() async {
    await init();
    await stop();

    _isPlaying = true;
    try {
      await _player?.stop();
      await _player?.play(AssetSource('sounds/berhasilbayar.mp3'));
    } catch (e) {
      debugPrint('[AlarmAudioService] Error playing payment success sound: $e');
    } finally {
      _isPlaying = false;
    }
  }

  /// Stop any currently playing alarm sound
  Future<void> stop() async {
    _activeSessionId++;
    _isPlaying = false;
    try {
      await _player?.stop();
    } catch (_) {}
  }

  void dispose() {
    _player?.dispose();
    _player = null;
  }
}
