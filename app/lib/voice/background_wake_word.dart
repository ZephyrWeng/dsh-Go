// The wake word while the app is off screen. The phone has one microphone, so
// this is the background half of listening: when the app leaves the front, the
// foreground listener (ui/wake_word_listener.dart) hands the microphone to a
// native foreground service (WakeWordService) that keeps capturing and streams
// the PCM here; a hit is delivered the same way as in the foreground.
//
// The spotter itself still runs in Dart — the engine outlives the activity
// (MainActivity.shouldDestroyEngineWithHost is false), so this isolate keeps
// decoding while the service owns the microphone.

import 'dart:async';

import 'package:flutter/services.dart';

import 'wake_word.dart';

/// The frames the background service captured, as 16 kHz mono PCM16LE.
final backgroundWakeWordFrames = const EventChannel('dsh/wake/events')
    .receiveBroadcastStream();

const _methods = MethodChannel('dsh/voice');

/// Starts the native foreground service that holds the microphone in the
/// background. The recorder only runs while a listener is subscribed.
Future<void> startBackgroundListening() => _methods.invokeMethod<void>('wakeStart');

/// Stops the native service and releases the microphone.
Future<void> stopBackgroundListening() => _methods.invokeMethod<void>('wakeStop');

/// Subscribes to the background service's PCM and feeds a [detector] with it.
///
/// The detector is started by the caller (it needs the model and keywords, which
/// live in the settings); this only wires the frames.
StreamSubscription<void> feedBackgroundPcm(WakeWordDetector detector) {
  return backgroundWakeWordFrames.listen((raw) {
    if (raw is! Map || raw['type'] != 'pcm') return;
    final bytes = raw['bytes'];
    if (raw['rate'] == 16000 && bytes is Uint8List && bytes.length == 640) {
      unawaited(detector.feed(bytes));
    }
  }, onError: (Object _) {
    // The service may be killed by the system; the listener's sync restarts it.
  });
}
