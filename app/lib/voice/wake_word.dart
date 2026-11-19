// The wake word: while the phone listens, sherpa's keyword spotter watches the
// audio for one phrase and, when it hears it, the caller hands the turn to voice
// call. Spotting runs in its own isolate: a keyword spotter is small, but it
// decodes on every 20 ms frame, and the UI thread must not pay for that.
//
// This class does not start the microphone and does not decide what to listen
// for: the caller feeds 16 kHz mono PCM16LE and passes the keywords text.
// Detection keeps running after a hit (the stream is reset so the same phrase is
// not reported twice for one utterance); stopping it is the caller's call.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'wake_word_model.dart';

export 'wake_word_model.dart';

/// One detection, as written in the keywords file (`@` alias included when the
/// entry has one, so the caller can tell two phrases apart).
class WakeWordHit {
  const WakeWordHit(this.keyword);
  final String keyword;

  /// The phrase without sherpa's `@alias`, which is what the person typed.
  String get phrase => keyword.contains('@') ? keyword.split('@').last.trim() : keyword;

  @override
  String toString() => 'WakeWordHit($keyword)';
}

/// A synchronous keyword spotter owned exclusively by the listening isolate.
abstract interface class WakeWordSpotter {
  /// Feeds mono samples; returns the keyword that completed in this chunk, or
  /// an empty string. Called once per audio frame.
  String feed(Float32List samples);
  void close();
}

typedef WakeWordSpotterFactory = WakeWordSpotter Function(WakeWordModel model, String keywords);

/// 16 kHz mono PCM16LE in; wake word out. This does not start the microphone.
class WakeWordDetector {
  WakeWordDetector({WakeWordSpotterFactory createSpotter = _SherpaSpotter.new})
    : _createSpotter = createSpotter; // ignore: prefer_initializing_formals

  final WakeWordSpotterFactory _createSpotter;
  final _hits = StreamController<WakeWordHit>.broadcast();
  Future<void> _tail = Future.value();
  _Worker? _worker;
  var _run = 0;
  var _loadedRun = 0;
  var _active = false;
  var _disposed = false;
  var _feeding = 0;

  /// Frames queued at most (a second of 20 ms frames). Spotting is cheaper than
  /// recognition, but a phone under load still drops audio instead of drifting
  /// further and further behind the microphone.
  static const maxQueued = 50;

  Stream<WakeWordHit> get hits => _hits.stream;

  /// True once [start] has loaded a spotter; false while stopping or failed.
  bool get active => _active && _loadedRun == _run;

  /// Loads the model and the keywords text. Subscribe to [hits] first.
  Future<void> start(WakeWordModel model, String keywords) {
    if (_disposed) return Future.error(StateError('WakeWordDetector is disposed'));
    final run = ++_run;
    return _enqueue(() async {
      if (run != _run) return;
      _active = false;
      if (_worker == null || _worker!.closed) {
        _worker = await _Worker.open(_createSpotter, (hit) {
          if (!_disposed && hit.run == _run) _hits.add(WakeWordHit(hit.keyword));
        });
      }
      await _worker!.request(_Start(run, model, keywords));
      _loadedRun = run;
      _active = true;
    });
  }

  /// Resolves after this frame has been spotted. Await it to apply backpressure.
  Future<void> feed(Uint8List pcm16le) {
    if (_disposed) return Future.error(StateError('WakeWordDetector is disposed'));
    if (pcm16le.length.isOdd) return Future.error(const FormatException('PCM16 must contain whole samples'));
    if (_feeding >= maxQueued) return Future.value();
    final run = _run;
    final pcm = TransferableTypedData.fromList([pcm16le]);
    _feeding++;
    return _enqueue(() async {
      try {
        if (run != _run) return;
        if (!active) throw StateError('WakeWordDetector is not started');
        try {
          await _worker!.request(_Feed(pcm));
        } catch (_) {
          _active = false;
          rethrow;
        }
      } finally {
        _feeding--;
      }
    });
  }

  /// Drops queued audio and releases the spotter. Safe to call when stopped.
  Future<void> stop() {
    if (_disposed) return _tail;
    _run++;
    return _enqueue(() => _stop());
  }

  Future<void> _stop() async {
    try {
      if (_worker != null && !_worker!.closed) await _worker!.request(const _Stop());
    } finally {
      _active = false;
    }
  }

  Future<void> dispose() {
    if (_disposed) return _tail;
    _disposed = true;
    _run++;
    return _enqueue(() async {
      try {
        await _stop();
      } finally {
        _worker?.close();
        _worker = null;
        await _hits.close();
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

class _Start {
  const _Start(this.run, this.model, this.keywords);
  final int run;
  final WakeWordModel model;
  final String keywords;
}

class _Feed {
  const _Feed(this.pcm);
  final TransferableTypedData pcm;
}

class _Stop {
  const _Stop();
}

class _Hit {
  const _Hit(this.run, this.keyword);
  final int run;
  final String keyword;
}

class _Done {
  const _Done();
}

class _Failure {
  const _Failure(this.message, this.stack);
  final String message;
  final String stack;
}

class _Worker {
  _Worker(this.onHit) {
    _receive.listen(_receiveMessage);
  }

  final void Function(_Hit) onHit;
  final _receive = ReceivePort();
  final _ready = Completer<SendPort>();
  late final Isolate _isolate;
  late final SendPort _commands;
  Completer<void>? _reply;
  bool closed = false;

  static Future<_Worker> open(WakeWordSpotterFactory createSpotter, void Function(_Hit) onHit) async {
    final worker = _Worker(onHit);
    try {
      worker._isolate = await Isolate.spawn(
        _listen,
        (worker._receive.sendPort, createSpotter),
        debugName: 'dsh-wake-word',
        onError: worker._receive.sendPort,
        onExit: worker._receive.sendPort,
      );
      worker._commands = await worker._ready.future;
      return worker;
    } catch (_) {
      worker._receive.close();
      rethrow;
    }
  }

  Future<void> request(Object command) {
    if (closed) return Future.error(StateError('Listening isolate has exited'));
    final reply = Completer<void>();
    _reply = reply;
    _commands.send(command);
    return reply.future;
  }

  void _receiveMessage(Object? message) {
    switch (message) {
      case SendPort():
        _ready.complete(message);
      case _Hit():
        onHit(message);
      case _Done():
        _reply!.complete();
        _reply = null;
      case _Failure():
        _reply!.completeError(StateError(message.message), StackTrace.fromString(message.stack));
        _reply = null;
      case null:
        _exited(StateError('Listening isolate has exited'), StackTrace.current);
      case List():
        _exited(StateError(message[0].toString()), StackTrace.fromString(message[1].toString()));
    }
  }

  void _exited(Object error, StackTrace stack) {
    closed = true;
    _receive.close();
    if (!_ready.isCompleted) _ready.completeError(error, stack);
    _reply?.completeError(error, stack);
    _reply = null;
  }

  void close() {
    closed = true;
    _receive.close();
    _isolate.kill();
  }
}

Future<void> _listen((SendPort, WakeWordSpotterFactory) arguments) async {
  final (replies, createSpotter) = arguments;
  final commands = ReceivePort();
  WakeWordSpotter? spotter;
  var run = 0;

  void release() {
    final current = spotter;
    spotter = null;
    current?.close();
  }

  replies.send(commands.sendPort);
  await for (final command in commands) {
    try {
      switch (command) {
        case _Start():
          release();
          spotter = createSpotter(command.model, command.keywords);
          run = command.run;
        case _Feed():
          final bytes = command.pcm.materialize().asByteData();
          final samples = Float32List(bytes.lengthInBytes ~/ 2);
          for (var i = 0; i < samples.length; i++) {
            samples[i] = bytes.getInt16(i * 2, Endian.little) / 32768.0;
          }
          final keyword = spotter!.feed(samples);
          if (keyword.isNotEmpty) replies.send(_Hit(run, keyword));
        case _Stop():
          release();
      }
      replies.send(const _Done());
    } catch (error, stack) {
      try {
        release();
      } finally {
        replies.send(_Failure(error.toString(), stack.toString()));
      }
    }
  }
}

class _SherpaSpotter implements WakeWordSpotter {
  factory _SherpaSpotter(WakeWordModel model, String keywords) {
    for (final path in [model.encoder, model.decoder, model.joiner, model.tokens]) {
      final stat = File(path).statSync();
      if (stat.type != FileSystemEntityType.file || stat.size == 0) {
        throw FileSystemException('Wake word model file is missing or empty', path);
      }
    }
    if (keywords.trim().isEmpty) throw ArgumentError.value(keywords, 'keywords', 'no keywords to listen for');
    sherpa.initBindings();
    final spotter = sherpa.KeywordSpotter(
      sherpa.KeywordSpotterConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: model.encoder,
            decoder: model.decoder,
            joiner: model.joiner,
          ),
          tokens: model.tokens,
          modelType: 'zipformer',
          numThreads: 1,
          debug: false,
        ),
        keywordsFile: '',
        keywordsScore: 1.0,
        keywordsThreshold: 0.25,
        maxActivePaths: 4,
      ),
    );
    try {
      return _SherpaSpotter._(spotter, spotter.createStream(keywords: keywords));
    } catch (_) {
      spotter.free();
      rethrow;
    }
  }

  _SherpaSpotter._(this._spotter, this._stream);

  final sherpa.KeywordSpotter _spotter;
  final sherpa.OnlineStream _stream;

  @override
  String feed(Float32List samples) {
    _stream.acceptWaveform(samples: samples, sampleRate: 16000);
    var decoded = false;
    while (_spotter.isReady(_stream)) {
      _spotter.decode(_stream);
      decoded = true;
    }
    if (!decoded) return '';
    final keyword = _spotter.getResult(_stream).keyword.trim();
    if (keyword.isEmpty) return '';
    _spotter.reset(_stream);
    return keyword;
  }

  @override
  void close() {
    try {
      _stream.free();
    } finally {
      _spotter.free();
    }
  }
}
