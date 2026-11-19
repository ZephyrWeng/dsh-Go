// A phrase becomes one line of a keywords file: pinyin tokens for the model, the
// words themselves after `@` for people reading the settings page or the log.
//
//   x iǎo sh ēn x iǎo sh ēn @小深小深
//
// sherpa matches tokens, not characters, so a custom wake word has to be spelled
// out with the same units `tokens.txt` uses: one initial (zh, sh, x, …) and one
// tone-marked final (iǎo, ēn, …) per character. Whatever the table cannot say —
// a character with no pinyin, an initial the model never saw — is reported as an
// error naming the syllable, because a phrase that does not tokenize would
// otherwise be saved and simply never wake anything.

import 'package:pinyin/pinyin.dart';

import 'wake_word_model.dart';

/// Why a phrase cannot be listened for.
enum WakeWordProblem {
  /// Nothing but spaces and punctuation.
  empty,

  /// Shorter than two characters, or longer than the model's phrase budget.
  length,

  /// Not Chinese: English words need the model's English phone set.
  script,

  /// A character has no pinyin at all.
  noPinyin,

  /// The pinyin split into units the model's `tokens.txt` does not contain.
  unsupported,
}

class WakeWordKeywordError implements Exception {
  const WakeWordKeywordError(this.problem, {this.offending = ''});
  final WakeWordProblem problem;

  /// The character or syllable that could not be used.
  final String offending;

  @override
  String toString() => 'WakeWordKeywordError($problem${offending.isEmpty ? '' : ', $offending'})';
}

/// Phrases offered before someone types their own.
const wakeWordPresets = ['小深小深', '鲸娘鲸娘', '开工开工'];

class WakeWordKeywords {
  WakeWordKeywords._();

  /// Shortest and longest phrase the spotter is given. Two characters is the
  /// least that survives a noisy room; past four, one more syllable per attempt
  /// costs more than it buys in accidental-wake resistance.
  static const minLength = 2;
  static const maxLength = 4;

  /// Initials in the order they must be tried: `zh` before `z`, `sh` before `s`.
  static const _initials = [
    'zh', 'ch', 'sh', 'b', 'p', 'm', 'f', 'd', 't', 'n', 'l', //
    'g', 'k', 'h', 'j', 'q', 'x', 'r', 'z', 'c', 's', 'y', 'w',
  ];

  /// The keywords line for [phrase], checked against the model's [tokens] when
  /// they are known. Without a downloaded model only the structural checks run:
  /// the phrase can be saved, and is verified against `tokens.txt` later.
  static String build(String phrase, {Set<String>? tokens}) {
    final text = _clean(phrase);
    if (text.isEmpty) throw const WakeWordKeywordError(WakeWordProblem.empty);
    if (text.length < minLength || text.length > maxLength) {
      throw WakeWordKeywordError(WakeWordProblem.length, offending: text);
    }
    final units = <String>[];
    for (final syllable in _syllables(text)) {
      units.addAll(_units(syllable, tokens));
    }
    if (units.isEmpty) throw WakeWordKeywordError(WakeWordProblem.unsupported, offending: text);
    return '${units.join(' ')} @$text';
  }

  /// Why [phrase] cannot be used, or null when it can — the dialog's inline check.
  static WakeWordKeywordError? problem(String phrase, {Set<String>? tokens}) {
    try {
      build(phrase, tokens: tokens);
      return null;
    } on WakeWordKeywordError catch (error) {
      return error;
    }
  }

  /// Keywords text for [phrases], one line each.
  static String buildAll(Iterable<String> phrases, {required Set<String> tokens}) =>
      phrases.map((phrase) => build(phrase, tokens: tokens)).join('\n');

  /// The keywords file for a downloaded model directory, or null when the model
  /// is not unpacked yet (there is nothing to check the tokens against).
  static Future<String?> forDirectory(String directory, Iterable<String> phrases) async {
    final model = wakeWordModelAt(directory);
    if (model == null) return null;
    final tokens = await readWakeWordTokens(model.tokens);
    return buildAll(phrases, tokens: tokens);
  }

  static String _clean(String phrase) {
    final buffer = StringBuffer();
    for (final rune in phrase.trim().runes) {
      if (_isHan(rune)) {
        buffer.write(String.fromCharCode(rune));
      } else if (_isLetter(rune)) {
        // Latin letters need the model's English phone set, which this build
        // does not ship; saying so beats silently dropping them.
        throw WakeWordKeywordError(WakeWordProblem.script, offending: String.fromCharCode(rune));
      }
      // Spaces, punctuation and the like are not part of what is said.
    }
    return buffer.toString();
  }

  static bool _isLetter(int rune) =>
      (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A) || (rune >= 0xFF21 && rune <= 0xFF5A);

  static bool _isHan(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) || (rune >= 0x3400 && rune <= 0x4DBF);

  /// One pinyin syllable per character, tone marks kept.
  static List<String> _syllables(String text) {
    final joined = PinyinHelper.getPinyin(text, separator: ' ', format: PinyinFormat.WITH_TONE_MARK).trim();
    final split = joined.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
    if (split.length == text.length) return split;
    // Word-level conversion changed the number of syllables (a rare polyphone
    // merged something); fall back to one character at a time.
    return [
      for (final rune in text.runes)
        PinyinHelper.getPinyin(String.fromCharCode(rune), separator: '', format: PinyinFormat.WITH_TONE_MARK),
    ];
  }

  /// `xiǎo` → `x`, `iǎo`; `ér` → `ér`. Both must be in the model's table, when
  /// the table is available.
  static List<String> _units(String syllable, Set<String>? tokens) {
    if (syllable.isEmpty) throw const WakeWordKeywordError(WakeWordProblem.noPinyin);
    for (final initial in _initials) {
      if (!syllable.startsWith(initial) || syllable.length == initial.length) continue;
      final finalPart = syllable.substring(initial.length);
      if (_known(initial, tokens) && _known(finalPart, tokens)) return [initial, finalPart];
    }
    // No initial (啊, 儿, 嗯 …): the syllable is the final on its own.
    if (_known(syllable, tokens)) return [syllable];
    throw WakeWordKeywordError(WakeWordProblem.unsupported, offending: syllable);
  }

  /// Without a model there is nothing to check against yet.
  static bool _known(String token, Set<String>? tokens) => tokens == null || tokens.contains(token);
}
