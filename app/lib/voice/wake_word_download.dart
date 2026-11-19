// Fetching the wake word model: one tar.bz2, resumed where it stopped, checked
// against its SHA-256, then unpacked on a worker isolate — bzip2 over 32 MB on
// the UI thread would be a visible stall, and this runs while the person is
// looking at the settings page.
//
// The archive also carries the model's test wavs; they are most of the download
// and none of what the spotter reads, so they are dropped rather than written.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'wake_word_model.dart';

export 'wake_word_model.dart';

enum WakeWordDownloadPhase { downloading, verifying, unpacking }

class WakeWordDownloadProgress {
  const WakeWordDownloadProgress(this.phase, this.doneBytes, this.totalBytes);
  final WakeWordDownloadPhase phase;
  final int doneBytes;
  final int totalBytes;

  double get fraction => totalBytes == 0 ? 0 : (doneBytes / totalBytes).clamp(0.0, 1.0);
}

class WakeWordDownloadCancelled implements Exception {}

/// One owner writes this directory; cancel keeps the `.part` file for next time.
class WakeWordDownloadStore {
  WakeWordDownloadStore(this.directory, {this.archive = wakeWordDefaultArchive});

  final Directory directory;
  final WakeWordArchive archive;
  Future<WakeWordModel>? _running;
  Future<void>? _deleting;
  HttpClient? _client;
  bool _cancelled = false;

  File get _part => File('${directory.path}/model.tar.bz2.part');

  /// Ready when the four files the spotter needs are unpacked here.
  Future<WakeWordModel?> installed() async => wakeWordModelAt(directory.path);

  /// Bytes already here: the unpacked archive counts as everything.
  Future<int> downloadedBytes() async {
    if (await installed() != null) return archive.bytes;
    final part = _part;
    return await part.exists() ? await part.length() : 0;
  }

  Future<WakeWordModel> download({void Function(WakeWordDownloadProgress)? onProgress}) {
    final deleting = _deleting;
    if (deleting != null) return deleting.then((_) => download(onProgress: onProgress));
    final running = _running;
    if (running != null) return running;
    _cancelled = false;
    late final Future<WakeWordModel> run;
    run = _download(onProgress).whenComplete(() {
      if (identical(_running, run)) _running = null;
    });
    _running = run;
    return run;
  }

  Future<void> cancel() async {
    _cancelled = true;
    _client?.close(force: true);
    try {
      await _running;
    } catch (_) {
      // The download reports its own end; cancelling only waits for it.
    }
  }

  Future<void> delete() {
    final deleting = _deleting;
    if (deleting != null) return deleting;
    late final Future<void> run;
    run =
        (() async {
          await cancel();
          if (await directory.exists()) await directory.delete(recursive: true);
        })().whenComplete(() {
          if (identical(_deleting, run)) _deleting = null;
        });
    _deleting = run;
    return run;
  }

  void _checkCancelled() {
    if (_cancelled) throw WakeWordDownloadCancelled();
  }

  Future<WakeWordModel> _download(void Function(WakeWordDownloadProgress)? progress) async {
    try {
      final ready = await installed();
      if (ready != null) return ready;
      await directory.create(recursive: true);
      await _fetch(progress);
      _checkCancelled();

      progress?.call(WakeWordDownloadProgress(WakeWordDownloadPhase.verifying, archive.bytes, archive.bytes));
      final part = _part;
      // Capture only what the worker isolate needs: a closure that reaches for
      // `this` (via `_part` or `_checkCancelled`) would drag the whole store — and
      // its `Future` fields, which cannot cross an isolate boundary — along.
      final partPath = part.path;
      final digest = await Isolate.run(() async => (await sha256.bind(File(partPath).openRead()).first).toString());
      _checkCancelled();
      if (digest != archive.sha256) {
        await part.delete();
        throw const FormatException('Wake word model checksum mismatch');
      }

      progress?.call(WakeWordDownloadProgress(WakeWordDownloadPhase.unpacking, 0, archive.bytes));
      final directoryPath = directory.path;
      await Isolate.run(() => _unpack(partPath, directoryPath));
      _checkCancelled();
      await part.delete();

      final model = await installed();
      if (model == null) throw const FormatException('Wake word model archive had no usable files');
      progress?.call(WakeWordDownloadProgress(WakeWordDownloadPhase.unpacking, archive.bytes, archive.bytes));
      return model;
    } catch (error) {
      if (_cancelled) throw WakeWordDownloadCancelled();
      rethrow;
    }
  }

  /// [archive] into the `.part` file from the first host that serves it.
  Future<void> _fetch(void Function(WakeWordDownloadProgress)? progress) async {
    Object? failure;
    for (final host in archive.hosts) {
      try {
        await _fetchFrom(archive.url(host), progress);
        return;
      } catch (error) {
        if (_cancelled) rethrow;
        failure = error;
      }
    }
    throw failure!;
  }

  Future<void> _fetchFrom(Uri url, void Function(WakeWordDownloadProgress)? progress) async {
    final part = _part;
    var offset = await part.exists() ? await part.length() : 0;
    if (offset > archive.bytes) offset = 0;
    if (offset == archive.bytes) return;
    final client = _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(url);
      if (offset > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      final response = await request.close().timeout(const Duration(seconds: 30));
      _checkCancelled();
      if (response.statusCode == HttpStatus.ok) {
        offset = 0; // The server ignored the range: start over.
      } else if (response.statusCode != HttpStatus.partialContent) {
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      final output = await part.open(mode: offset == 0 ? FileMode.write : FileMode.append);
      var done = offset;
      var tooLong = false;
      var reportedAt = -250;
      final clock = Stopwatch()..start();
      try {
        await for (final bytes in response.timeout(const Duration(seconds: 30))) {
          _checkCancelled();
          if (done + bytes.length > archive.bytes) {
            tooLong = true;
            break;
          }
          await output.writeFrom(bytes);
          done += bytes.length;
          if (clock.elapsedMilliseconds - reportedAt >= 250) {
            reportedAt = clock.elapsedMilliseconds;
            progress?.call(WakeWordDownloadProgress(WakeWordDownloadPhase.downloading, done, archive.bytes));
          }
        }
      } finally {
        await output.close();
      }
      if (tooLong) {
        // Not the archive it should be: nothing of it is kept.
        await part.delete();
        throw HttpException('Larger than expected', uri: url);
      }
      if (done != archive.bytes) throw HttpException('Incomplete download', uri: url);
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }
}

/// Runs on a worker isolate: bzip2, then the four entries the spotter loads.
void _unpack(String archivePath, String directory) {
  final compressed = File(archivePath).readAsBytesSync();
  final tar = BZip2Decoder().decodeBytes(compressed);
  final entries = TarDecoder().decodeBytes(tar).files;
  var written = 0;
  for (final entry in entries) {
    final bytes = entry.readBytes();
    if (bytes == null) continue;
    final name = entry.name.split('/').last;
    final isModel =
        name.endsWith('.onnx') &&
        (name.startsWith(wakeWordEncoderPrefix) ||
            name.startsWith(wakeWordDecoderPrefix) ||
            name.startsWith(wakeWordJoinerPrefix));
    if (!isModel && name != wakeWordTokensName) continue; // test wavs, README, scripts
    File('$directory/$name').writeAsBytesSync(bytes, flush: true);
    written++;
  }
  if (written < 4) throw FormatException('Wake word model archive carried $written files, expected 4');
}
