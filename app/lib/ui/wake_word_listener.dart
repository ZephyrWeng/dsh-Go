// The listener that makes the wake word true: while the app is in front and the
// switch is on, the microphone stays with the keyword spotter; a hit hands the
// turn to voice call with the conversation on screen.
//
// When the app leaves the front (screen off, or another app), the microphone is
// handed to a native foreground service that keeps listening, so the wake word
// still works. The spotter runs in Dart the whole time; only the microphone's
// owner changes.
//
// The foreground recorder is the one dictation uses, so listening stops the
// moment anything else wants the microphone: a call in progress, or the app
// leaving the front.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/app_foreground.dart' as app_foreground;
import '../state/notify_state.dart';
import '../state/sessions_state.dart';
import '../state/streaming_pcm_state.dart';
import '../state/voice_state.dart';
import '../state/wake_word_state.dart';
import '../ui/chat/voice/voice_bridge.dart';
import '../ui/speech/voice_call_page.dart';
import '../voice/background_wake_word.dart';
import '../voice/streaming_pcm.dart';
import '../voice/wake_word.dart';
import '../voice/wake_word_keywords.dart';

class WakeWordListener extends ConsumerStatefulWidget {
  const WakeWordListener({super.key, required this.navigatorKey});

  /// The app's navigator: a wake happens with no page of its own to push from.
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  ConsumerState<WakeWordListener> createState() => _WakeWordListenerState();
}

class _WakeWordListenerState extends ConsumerState<WakeWordListener> with WidgetsBindingObserver {
  WakeWordDetector? _detector;
  StreamSubscription<void>? _frames;
  StreamSubscription<void>? _backgroundFrames;
  bool _starting = false;
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed = WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_sync()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stop());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    unawaited(_sync());
  }

  /// Listening is on exactly when the switch is on, the model is unpacked, and
  /// no call is up. In front, the dictation recorder feeds the spotter; off
  /// screen, a foreground service does.
  Future<void> _sync() async {
    if (!mounted) return;
    final settings = await ref.read(wakeWordSettingsProvider.notifier).ready();
    final model = await ref.read(wakeWordModelProvider.future);
    final wanted = settings.enabled && model != null && ref.read(callChatProvider) == null;
    if (wanted && _detector == null && !_starting) {
      await _start(model, settings.phrase);
    } else if (!wanted && _detector != null) {
      await _stop();
    } else if (wanted && _detector != null) {
      // Already listening: switch the microphone's owner to match the lifecycle.
      await _switchOwner(model, settings.phrase);
    }
  }

  Future<void> _start(WakeWordModel model, String phrase) async {
    _starting = true;
    final detector = WakeWordDetector();
    final bridge = ref.read(voiceBridgeProvider);
    try {
      final keywords = WakeWordKeywords.build(phrase, tokens: await readWakeWordTokens(model.tokens));
      final permission = await bridge.requestPermission();
      if (permission != VoicePermission.granted) return; // No microphone: nothing to listen with.
      await detector.start(model, keywords);
      detector.hits.listen(_wake);
      _detector = detector;
      await _switchOwner(model, phrase);
    } on WakeWordKeywordError {
      // The phrase cannot be spelled with this model: turning the switch off is
      // the honest answer, and the settings page explains why.
      unawaited(ref.read(wakeWordSettingsProvider.notifier).setEnabled(false));
      await detector.dispose();
    } catch (_) {
      // Busy microphone, a recorder that refused, a model that failed to load:
      // the next _sync tries again rather than leaving a half-started listener.
      await detector.dispose();
    } finally {
      _starting = false;
    }
  }

  /// Routes the microphone to the right owner for [_resumed]: the dictation
  /// recorder in front, the native service off screen. The spotter is unchanged.
  Future<void> _switchOwner(WakeWordModel model, String phrase) async {
    final detector = _detector;
    if (detector == null) return;
    if (_resumed) {
      await _stopBackground();
      await _startForeground(detector);
    } else {
      await _stopForeground();
      await _startBackground(detector);
    }
  }

  Future<void> _startForeground(WakeWordDetector detector) async {
    if (_frames != null) return;
    final bridge = ref.read(voiceBridgeProvider);
    final capture = ref.read(streamingPcmCaptureProvider);
    try {
      await bridge.startRecorder(maxSeconds: 600);
      _frames = capture.frames.listen((pcm) => unawaited(detector.feed(pcm)));
      await capture.start(StreamingPcmSource.dictation);
    } catch (_) {
      await _frames?.cancel();
      _frames = null;
    }
  }

  Future<void> _startBackground(WakeWordDetector detector) async {
    if (_backgroundFrames != null) return;
    try {
      await startBackgroundListening();
      _backgroundFrames = feedBackgroundPcm(detector);
    } catch (_) {
      // The service could not start (no permission, a ROM that refuses): fall
      // back to no listening; the next _sync retries.
      await _backgroundFrames?.cancel();
      _backgroundFrames = null;
    }
  }

  Future<void> _stopForeground() async {
    final frames = _frames;
    _frames = null;
    await frames?.cancel();
    try {
      await ref.read(streamingPcmCaptureProvider).stop();
      await ref.read(voiceBridgeProvider).cancel();
    } catch (_) {
      // Already stopped.
    }
  }

  Future<void> _stopBackground() async {
    final frames = _backgroundFrames;
    _backgroundFrames = null;
    await frames?.cancel();
    try {
      await stopBackgroundListening();
    } catch (_) {
      // The service is already gone.
    }
  }

  Future<void> _stop() async {
    final detector = _detector;
    _detector = null;
    await _stopForeground();
    await _stopBackground();
    await detector?.dispose();
  }

  /// A phrase was heard: give the microphone back, then talk.
  Future<void> _wake(WakeWordHit hit) async {
    if (!mounted) return;
    await _stop();
    // Off screen, the app must come forward before it can hand the turn to a
    // call page; the navigator may not even have a context yet.
    if (!_resumed) {
      await ref.read(app_foreground.appForegroundProvider)();
      // The activity is coming up; the navigator's context may not be ready on
      // the next line, so wait one frame for the lifecycle to settle.
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final context = widget.navigatorKey.currentContext;
    if (context == null || !context.mounted || !mounted) return;
    final current = ref.read(currentSessionProvider);
    await openChatCall(
      context,
      title: appL10n.commonNewChat,
      session: () async {
        if (current != null) return current;
        try {
          return await ref.read(sessionsProvider.notifier).create();
        } catch (_) {
          return null;
        }
      },
    );
    // Back from the call: listen again if it is still wanted.
    unawaited(_sync());
  }

  @override
  Widget build(BuildContext context) {
    // The switch, the phrase and the model are all read in _sync; rebuild when
    // any of them changes so a settings change takes effect without a restart.
    ref.listen(wakeWordSettingsProvider, (_, _) => unawaited(_sync()));
    ref.listen(wakeWordModelProvider, (_, _) => unawaited(_sync()));
    ref.listen(callChatProvider, (_, _) => unawaited(_sync()));
    return const SizedBox.shrink();
  }
}

