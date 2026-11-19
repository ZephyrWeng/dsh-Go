// What the wake word settings are, and where the model lives.
//
// The listening itself is not here: it needs the microphone, the recorder and a
// route into voice call, so it lives next to the settings page that turns it on
// (ui/settings/wake_word.dart). This file only remembers the two answers a person
// gives — whether the phone listens, and what it listens for.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../voice/wake_word_download.dart';

/// The phrase offered before someone types their own, and the one that survives
/// a first install: four syllables stay rare in ordinary speech.
const wakeWordDefaultPhrase = '小深小深';

class WakeWordSettings {
  const WakeWordSettings({this.enabled = false, this.phrase = wakeWordDefaultPhrase});

  final bool enabled;
  final String phrase;

  WakeWordSettings copyWith({bool? enabled, String? phrase}) =>
      WakeWordSettings(enabled: enabled ?? this.enabled, phrase: phrase ?? this.phrase);
}

class WakeWordSettingsController extends Notifier<WakeWordSettings> {
  static const enabledKey = 'wake_word_enabled';
  static const phraseKey = 'wake_word_phrase';
  late Future<void> _loaded;

  @override
  WakeWordSettings build() {
    _loaded = _load();
    return const WakeWordSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final phrase = prefs.getString(phraseKey);
      state = WakeWordSettings(
        enabled: prefs.getBool(enabledKey) ?? false,
        phrase: (phrase == null || phrase.isEmpty) ? wakeWordDefaultPhrase : phrase,
      );
    } catch (_) {
      // Unreadable preferences: off, with the default phrase, for this run.
    }
  }

  Future<WakeWordSettings> ready() async {
    await _loaded;
    return ref.mounted ? state : const WakeWordSettings();
  }

  Future<void> setEnabled(bool enabled) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(enabled: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, enabled);
  }

  Future<void> setPhrase(String phrase) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(phrase: phrase.trim());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(phraseKey, phrase.trim());
  }
}

final wakeWordSettingsProvider = NotifierProvider<WakeWordSettingsController, WakeWordSettings>(
  WakeWordSettingsController.new,
);

/// Where the unpacked model lives: app support, not cache — a 30 MB download
/// should survive the system reclaiming space.
final wakeWordDirectoryProvider = FutureProvider<Directory>((ref) async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/wake_word');
});

final wakeWordStoreProvider = FutureProvider<WakeWordDownloadStore>((ref) async {
  final directory = await ref.watch(wakeWordDirectoryProvider.future);
  return WakeWordDownloadStore(directory);
});

/// The unpacked model, or null until the archive has been downloaded.
final wakeWordModelProvider = FutureProvider<WakeWordModel?>((ref) async {
  final store = await ref.watch(wakeWordStoreProvider.future);
  return store.installed();
});
