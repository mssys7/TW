// audio_recorder_player_service.dart
// Production-ready audio recording and playback pipeline for Half-Duplex Walkie-Talkies.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

enum AudioRadioState {
  idle,
  recording,
  playing,
  processing,
}

class AudioRecorderPlayerService {
  static final AudioRecorderPlayerService _instance = AudioRecorderPlayerService._internal();
  factory AudioRecorderPlayerService() => _instance;
  AudioRecorderPlayerService._internal();

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final Uuid _uuid = const Uuid();

  // Internal state tracking
  AudioRadioState _state = AudioRadioState.idle;
  String? _currentRecordingPath;
  DateTime? _recordStartTime;

  // Reactive state stream
  final _stateController = StreamController<AudioRadioState>.broadcast();
  final _playbackFinishedController = StreamController<void>.broadcast();

  Stream<AudioRadioState> get stateStream => _stateController.stream;
  Stream<void> get playbackFinishedStream => _playbackFinishedController.stream;
  AudioRadioState get currentState => _state;

  bool _isInitialized = false;

  /// Initializes audio session and low-latency audio player modes
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Configure audioplayer for low-latency voice walkie-talkie speaker output
    await _audioPlayer.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: [
            AVAudioSessionOptions.defaultToSpeaker,
            AVAudioSessionOptions.mixWithOthers,
          ],
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.voiceCommunication,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ),
    );

    // Listen for playback completion to clean up temp files immediately
    _audioPlayer.onPlayerComplete.listen((_) {
      _setState(AudioRadioState.idle);
      _playbackFinishedController.add(null);
    });

    _isInitialized = true;
  }

  /// Step 1: Start recording compressed voice payload
  /// Uses AAC-LC or Opus with 16kHz-24kHz sample rate to produce <100KB files for 5-10s talk bursts
  Future<void> startRecording() async {
    if (_state != AudioRadioState.idle) {
      debugPrint("[AudioService] Cannot start recording while state is $_state");
      return;
    }

    try {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!hasPermission) {
        throw Exception("Microphone permission not granted for audio capture");
      }

      final tempDir = await getTemporaryDirectory();
      final String filename = "ptt_out_${_uuid.v4()}.m4a";
      _currentRecordingPath = "${tempDir.path}/$filename";

      // Tactical radio audio configuration:
      // - AAC-LC (MPEG4) or Opus gives high intelligibility at minimal bitrates
      // - 24,000 Hz sample rate (sufficient for human voice)
      // - 24 kbps bitrate ensures ~3KB per second (a 5-second PTT burst is only ~15 KB!)
      const recordConfig = RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 24000,
        sampleRate: 24000,
        numChannels: 1, // Mono saves 50% bandwidth
      );

      _setState(AudioRadioState.recording);
      _recordStartTime = DateTime.now();

      await _audioRecorder.start(
        recordConfig,
        path: _currentRecordingPath!,
      );

      debugPrint("[AudioService] Recording started -> $_currentRecordingPath");
    } catch (e) {
      _setState(AudioRadioState.idle);
      debugPrint("[AudioService] startRecording failed: $e");
      rethrow;
    }
  }

  /// Step 2: Finalize recording, enforce minimal duration, read bytes, and clean up source file
  Future<Uint8List?> stopAndGetAudioBytes() async {
    if (_state != AudioRadioState.recording) {
      return null;
    }

    _setState(AudioRadioState.processing);

    try {
      final String? path = await _audioRecorder.stop();
      final elapsed = _recordStartTime != null
          ? DateTime.now().difference(_recordStartTime!).inMilliseconds
          : 0;

      // Ignore accidental micro-taps under 350ms to prevent ghost clicks
      if (elapsed < 350 || path == null) {
        debugPrint("[AudioService] Audio tap too brief ($elapsed ms), discarding.");
        _cleanupFile(path);
        _setState(AudioRadioState.idle);
        return null;
      }

      final recordedFile = File(path);
      if (!await recordedFile.exists()) {
        _setState(AudioRadioState.idle);
        return null;
      }

      final Uint8List audioBytes = await recordedFile.readAsBytes();
      debugPrint("[AudioService] Recorded ${audioBytes.lengthInBytes} bytes in $elapsed ms");

      // Clean up the recorded temp file asynchronously
      _cleanupFile(path);
      _setState(AudioRadioState.idle);
      return audioBytes;
    } catch (e) {
      _setState(AudioRadioState.idle);
      debugPrint("[AudioService] stopAndGetAudioBytes failed: $e");
      return null;
    }
  }

  /// Step 3: Receiver pipeline — accepts incoming raw bytes, writes to sandbox temp, and auto-plays
  Future<void> playIncomingAudio(Uint8List audioBytes) async {
    if (audioBytes.isEmpty) return;

    try {
      _setState(AudioRadioState.playing);

      final tempDir = await getTemporaryDirectory();
      final String tempFilePath = "${tempDir.path}/ptt_in_${_uuid.v4()}.m4a";
      final tempFile = File(tempFilePath);

      // Write incoming byte stream to disk
      await tempFile.writeAsBytes(audioBytes, flush: true);
      debugPrint("[AudioService] Incoming audio written (${audioBytes.lengthInBytes} bytes), initiating playback...");

      // Stop any active playback before starting new transmission
      await _audioPlayer.stop();

      // Play audio payload directly through loudspeaker
      await _audioPlayer.play(
        DeviceFileSource(tempFilePath),
        volume: 1.0,
      );

      // Automatically queue file cleanup once playback concludes
      _audioPlayer.onPlayerComplete.first.then((_) {
        _cleanupFile(tempFilePath);
      });
    } catch (e) {
      _setState(AudioRadioState.idle);
      debugPrint("[AudioService] playIncomingAudio failed: $e");
    }
  }

  /// Deletes temporary audio artifacts to prevent device storage bloat
  Future<void> _cleanupFile(String? filePath) async {
    if (filePath == null) return;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint("[AudioService] Failed cleaning temp file: $e");
    }
  }

  void _setState(AudioRadioState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  /// Releases audio recorder and player handles
  Future<void> dispose() async {
    await _audioRecorder.dispose();
    await _audioPlayer.dispose();
    await _stateController.close();
    await _playbackFinishedController.close();
  }
}
