// 设置 › 语音 › 唤醒词: the switch, the phrase, the model, and a way to try the
// phrase without leaving the page.
//
// The phrase is what the phone listens for; the model is what hears it. Both are
// needed before the switch does anything, so the switch stays off while the model
// is missing rather than promising something that cannot happen.
//
// Listening itself is not started here: this page runs a short foreground test
// through the same recorder dictation uses, and the always-on listener is opened
// by the caller that owns the microphone (ui/settings/wake_word.dart's host).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/streaming_pcm_state.dart';
import '../../state/voice_state.dart';
import '../../state/wake_word_state.dart';
import '../../voice/streaming_pcm.dart';
import '../../voice/wake_word.dart';
import '../../voice/wake_word_download.dart';
import '../../voice/wake_word_keywords.dart';
import '../chat/voice/voice_bridge.dart';
import '../theme/app_icons.dart';
import 'settings_widgets.dart';

class WakeWordSection extends ConsumerStatefulWidget {
  const WakeWordSection({super.key});

  @override
  ConsumerState<WakeWordSection> createState() => _WakeWordSectionState();
}

class _WakeWordSectionState extends ConsumerState<WakeWordSection> {
  WakeWordDownloadProgress? _progress;
  bool _downloading = false;
  bool _testing = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    // The archive may have finished while the app was away.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(wakeWordModelProvider);
    });
  }

  Future<void> _toggle(bool on, WakeWordModel? model) async {
    if (on && model == null) {
      _say(context.l10n.wakeWordTestNeedModel);
      return;
    }
    await ref.read(wakeWordSettingsProvider.notifier).setEnabled(on);
  }

  Future<void> _download() async {
    final store = await ref.read(wakeWordStoreProvider.future);
    setState(() {
      _downloading = true;
      _progress = const WakeWordDownloadProgress(WakeWordDownloadPhase.downloading, 0, 1);
    });
    try {
      await store.download(onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      });
      ref.invalidate(wakeWordModelProvider);
      if (mounted) setState(() => _progress = null);
    } catch (error) {
      if (mounted) {
        setState(() => _progress = null);
        _say(context.l10n.wakeWordModelFailed(_reason(error)));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _deleteModel() async {
    final store = await ref.read(wakeWordStoreProvider.future);
    setState(() => _deleting = true);
    try {
      await ref.read(wakeWordSettingsProvider.notifier).setEnabled(false);
      await store.delete();
      ref.invalidate(wakeWordModelProvider);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  /// One foreground listen, through the recorder dictation already uses. The
  /// result is shown here; waking a call is the always-on listener's job.
  Future<void> _test(WakeWordModel model, String phrase) async {
    final l10n = context.l10n;
    String keywords;
    try {
      keywords = WakeWordKeywords.build(phrase, tokens: await readWakeWordTokens(model.tokens));
    } on WakeWordKeywordError catch (error) {
      _say(_problemText(l10n, error));
      return;
    }
    final bridge = ref.read(voiceBridgeProvider);
    final permission = await bridge.requestPermission();
    if (permission != VoicePermission.granted) {
      _say(l10n.wakeWordMicDenied);
      return;
    }
    setState(() => _testing = true);
    final detector = WakeWordDetector();
    final capture = ref.read(streamingPcmCaptureProvider);
    StreamSubscription<void>? frames;
    var heard = '';
    final hit = Completer<String>();
    final subscription = detector.hits.listen((event) {
      if (!hit.isCompleted) hit.complete(event.phrase);
    });
    try {
      await detector.start(model, keywords);
      await bridge.startRecorder(maxSeconds: 8);
      frames = capture.frames.listen((pcm) => unawaited(detector.feed(pcm)));
      await capture.start(StreamingPcmSource.dictation);
      heard = await hit.future.timeout(const Duration(seconds: 8), onTimeout: () => '');
      _say(heard.isEmpty ? l10n.wakeWordTestMissed : l10n.wakeWordTestHeard(heard));
    } catch (error) {
      _say(l10n.wakeWordModelFailed(_reason(error)));
    } finally {
      await frames?.cancel();
      await capture.stop();
      await bridge.cancel();
      await subscription.cancel();
      await detector.dispose();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _editPhrase(WakeWordModel? model) async {
    final l10n = context.l10n;
    final current = ref.read(wakeWordSettingsProvider).phrase;
    final tokens = model == null ? null : await readWakeWordTokens(model.tokens);
    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => _PhraseDialog(initial: current, tokens: tokens),
    );
    if (chosen == null || chosen.isEmpty) return;
    await ref.read(wakeWordSettingsProvider.notifier).setPhrase(chosen);
    if (mounted) _say(l10n.wakeWordPhraseSaved);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  String _reason(Object error) => error is WakeWordDownloadCancelled ? 'cancelled' : error.toString();

  String _problemText(L10n l10n, WakeWordKeywordError error) => switch (error.problem) {
    WakeWordProblem.empty || WakeWordProblem.length => l10n.wakeWordPhraseInvalidLength,
    WakeWordProblem.script => l10n.wakeWordPhraseInvalidScript(error.offending),
    WakeWordProblem.noPinyin || WakeWordProblem.unsupported => l10n.wakeWordPhraseUnsupported(error.offending),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = ref.watch(wakeWordSettingsProvider);
    final model = ref.watch(wakeWordModelProvider).value;
    final ready = model != null;
    return SettingsSection(
      title: l10n.wakeWordSection,
      footer: Text(settings.enabled ? l10n.wakeWordEnableHint(settings.phrase) : l10n.wakeWordEnableOffHint),
      children: [
        SettingsTile(
          key: const ValueKey('wake-enable'),
          icon: AppIcons.voice,
          title: l10n.wakeWordEnable,
          subtitle: ready ? null : l10n.wakeWordTestNeedModel,
          trailing: Switch.adaptive(
            value: settings.enabled && ready,
            onChanged: _downloading ? null : (on) => unawaited(_toggle(on, model)),
          ),
          onTap: () => unawaited(_toggle(!settings.enabled, model)),
        ),
        SettingsTile(
          key: const ValueKey('wake-phrase'),
          title: l10n.wakeWordPhrase,
          subtitle: l10n.wakeWordPhraseHint,
          value: Text(settings.phrase),
          onTap: () => unawaited(_editPhrase(model)),
        ),
        if (!ready)
          SettingsTile(
            key: const ValueKey('wake-model'),
            icon: AppIcons.download,
            title: l10n.wakeWordModel,
            subtitle: _downloading ? null : l10n.wakeWordModelSize,
            value: Text(_progressLabel(l10n)),
            onTap: _downloading ? null : () => unawaited(_download()),
          )
        else ...[
          SettingsTile(
            key: const ValueKey('wake-model-ready'),
            icon: AppIcons.download,
            title: l10n.wakeWordModel,
            value: Text(l10n.wakeWordModelReady),
            onTap: _testing ? null : () => unawaited(_test(model, settings.phrase)),
            trailing: TextButton(
              onPressed: _testing ? null : () => unawaited(_test(model, settings.phrase)),
              child: Text(_testing ? l10n.wakeWordTestListening(settings.phrase) : l10n.wakeWordTest),
            ),
          ),
          SettingsTile(
            key: const ValueKey('wake-model-delete'),
            title: l10n.wakeWordModelDelete,
            danger: true,
            onTap: _deleting ? null : () => unawaited(_deleteModel()),
          ),
        ],
      ],
    );
  }

  String _progressLabel(L10n l10n) {
    final progress = _progress;
    if (!_downloading || progress == null) return l10n.wakeWordModelDownload;
    if (progress.phase == WakeWordDownloadPhase.unpacking) return l10n.wakeWordModelUnpacking;
    return l10n.wakeWordModelDownloading((progress.fraction * 100).round());
  }
}

class _PhraseDialog extends StatefulWidget {
  const _PhraseDialog({required this.initial, required this.tokens});
  final String initial;
  final Set<String>? tokens;

  @override
  State<_PhraseDialog> createState() => _PhraseDialogState();
}

class _PhraseDialogState extends State<_PhraseDialog> {
  late final TextEditingController _input = TextEditingController(text: widget.initial);
  WakeWordKeywordError? _error;

  @override
  void initState() {
    super.initState();
    _check(widget.initial);
  }

  void _check(String value) => setState(() => _error = value.trim().isEmpty ? null : WakeWordKeywords.problem(value, tokens: widget.tokens));

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final error = _error;
    return AlertDialog(
      title: Text(l10n.wakeWordPhrase),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _input,
            autofocus: true,
            maxLength: WakeWordKeywords.maxLength,
            decoration: InputDecoration(hintText: l10n.wakeWordPhraseHint),
            onChanged: _check,
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final preset in wakeWordPresets)
                ActionChip(
                  label: Text(preset),
                  onPressed: () {
                    _input.text = preset;
                    _check(preset);
                  },
                ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                switch (error.problem) {
                  WakeWordProblem.empty || WakeWordProblem.length => l10n.wakeWordPhraseInvalidLength,
                  WakeWordProblem.script => l10n.wakeWordPhraseInvalidScript(error.offending),
                  WakeWordProblem.noPinyin ||
                  WakeWordProblem.unsupported => l10n.wakeWordPhraseUnsupported(error.offending),
                },
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _error != null ? null : () => Navigator.of(context).pop(_input.text.trim()),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
