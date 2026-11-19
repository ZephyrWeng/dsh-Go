// The wake word model: sherpa-onnx's Chinese–English keyword spotter (3.3M
// parameters, int8, Apache-2.0). Upstream publishes it only as one tar.bz2 on
// the project's GitHub release, so the app downloads that archive and keeps the
// four files the spotter needs — the test wavs inside are two thirds of the
// download and are dropped.
//
// Everything here is about identity and layout. Fetching lives in
// wake_word_download.dart, the spotter itself in wake_word.dart.

import 'dart:convert';
import 'dart:io';

/// Where the spotter reads from, once the archive is unpacked.
class WakeWordModel {
  const WakeWordModel({
    required this.directory,
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  final String directory;
  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
}

/// One archive, two hosts: GitHub first, then a mirror that answers in China.
class WakeWordArchive {
  const WakeWordArchive({required this.hosts, required this.path, required this.bytes, required this.sha256});

  final List<String> hosts;
  final String path;
  final int bytes;
  final String sha256;

  Uri url(String host) => Uri.parse('$host/$path');
}

const wakeWordDefaultArchive = WakeWordArchive(
  hosts: [
    'https://github.com/k2-fsa/sherpa-onnx/releases/download',
    'https://ghproxy.net/https://github.com/k2-fsa/sherpa-onnx/releases/download',
  ],
  path: 'kws-models/sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20.tar.bz2',
  bytes: 32885699,
  sha256: '68447f4fbc67e70eee3a93961f36e81e98f47aef73ce7e7ca00885c6cd3616a6',
);

/// The file stems the spotter needs, matched by prefix inside the archive so a
/// rebuild of the same model (new epoch count in the name) still loads.
const wakeWordEncoderPrefix = 'encoder-';
const wakeWordDecoderPrefix = 'decoder-';
const wakeWordJoinerPrefix = 'joiner-';
const wakeWordTokensName = 'tokens.txt';

/// Resolves the model layout in [directory], or null when it is not unpacked.
WakeWordModel? wakeWordModelAt(String directory) {
  final dir = Directory(directory);
  if (!dir.existsSync()) return null;
  String? encoder;
  String? decoder;
  String? joiner;
  for (final entry in dir.listSync(followLinks: false)) {
    if (entry is! File) continue;
    final name = entry.uri.pathSegments.last;
    if (!name.endsWith('.onnx')) continue;
    if (name.startsWith(wakeWordEncoderPrefix)) {
      encoder = name;
    } else if (name.startsWith(wakeWordDecoderPrefix)) {
      decoder = name;
    } else if (name.startsWith(wakeWordJoinerPrefix)) {
      joiner = name;
    }
  }
  final tokens = File('$directory/$wakeWordTokensName');
  if (encoder == null || decoder == null || joiner == null || !tokens.existsSync()) return null;
  return WakeWordModel(
    directory: directory,
    encoder: '$directory/$encoder',
    decoder: '$directory/$decoder',
    joiner: '$directory/$joiner',
    tokens: tokens.path,
  );
}

/// The row labels of `tokens.txt`, which is what a keywords line may use.
///
/// A generated keyword must consist of these tokens only; that is the check that
/// turns "this phrase cannot be said" into a message instead of a phrase that
/// silently never fires.
Future<Set<String>> readWakeWordTokens(String tokensPath) async {
  final tokens = <String>{};
  await for (final line in File(tokensPath)
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final token = line.split(' ').first.trim();
    if (token.isNotEmpty) tokens.add(token);
  }
  return tokens;
}
