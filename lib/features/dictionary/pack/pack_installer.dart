import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'kaikki_converter.dart';

enum PackInstallPhase { downloading, installing }

class PackInstallProgress {
  const PackInstallProgress(this.phase, this.received, this.total);

  final PackInstallPhase phase;
  final int received;

  /// Null when the server does not say.
  final int? total;

  double? get fraction =>
      total == null || total == 0 ? null : (received / total!).clamp(0, 1);
}

/// A download running in a background isolate. It streams the gzipped
/// kaikki file straight into the converter, so nothing but the finished
/// pack is written to disk.
class PackInstallJob {
  PackInstallJob._(this._partPath) {
    // Callers may cancel before listening to [done]; don't report that as
    // an unhandled error.
    _done.future.ignore();
  }

  final String _partPath;
  final _progress = StreamController<PackInstallProgress>.broadcast();
  final _done = Completer<void>();
  Isolate? _isolate;
  ReceivePort? _port;
  bool _cancelled = false;

  Stream<PackInstallProgress> get progress => _progress.stream;

  /// Completes when the pack is in place; fails with [PackInstallCancelled]
  /// or the download or conversion error.
  Future<void> get done => _done.future;

  static Future<PackInstallJob> start({
    required Uri uri,
    required String partPath,
    required String finalPath,
    required String language,
    required String languageName,
  }) async {
    final job = PackInstallJob._(partPath);
    final port = ReceivePort();
    job._port = port;
    port.listen(job._onMessage);
    try {
      job._isolate = await Isolate.spawn(
        _installEntry,
        [
          port.sendPort,
          uri.toString(),
          partPath,
          finalPath,
          language,
          languageName,
        ],
        onError: port.sendPort,
        onExit: port.sendPort,
        errorsAreFatal: true,
      );
    } catch (error) {
      job._finish(error);
    }
    return job;
  }

  void _onMessage(Object? message) {
    if (_done.isCompleted) return;
    if (message is List && message.isNotEmpty && message.first is String) {
      switch (message.first) {
        case 'progress':
          _progress.add(
            PackInstallProgress(
              PackInstallPhase.downloading,
              message[1] as int,
              message[2] as int?,
            ),
          );
        case 'installing':
          _progress.add(
            PackInstallProgress(
              PackInstallPhase.installing,
              message[1] as int,
              message[2] as int?,
            ),
          );
        case 'done':
          _finish(null);
        case 'error':
          _finish(PackInstallException(message[1] as String));
      }
      return;
    }
    if (message is List) {
      // Uncaught isolate error: [message, stack].
      _finish(PackInstallException('${message.first}'));
      return;
    }
    // onExit without a result.
    _finish(
      _cancelled
          ? const PackInstallCancelled()
          : const PackInstallException('The installer stopped unexpectedly.'),
    );
  }

  void _finish(Object? error) {
    if (_done.isCompleted) return;
    _port?.close();
    _progress.close();
    if (error == null) {
      _done.complete();
    } else {
      _done.completeError(error);
    }
  }

  /// Stops the download and removes the partial file.
  Future<void> cancel() async {
    if (_done.isCompleted) return;
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    _finish(const PackInstallCancelled());
    final part = File(_partPath);
    // The isolate may still hold the file briefly; deleting is still safe.
    for (final file in [part, File('$_partPath-journal')]) {
      try {
        if (file.existsSync()) await file.delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }
}

class PackInstallException implements Exception {
  const PackInstallException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PackInstallCancelled implements Exception {
  const PackInstallCancelled();

  @override
  String toString() => 'Download cancelled.';
}

Future<void> _installEntry(List<Object?> args) async {
  final send = args[0] as SendPort;
  final uri = Uri.parse(args[1] as String);
  final partPath = args[2] as String;
  final finalPath = args[3] as String;
  final client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'Bookmunity dictionary installer';
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      send.send(['error', 'The server answered ${response.statusCode}.']);
      return;
    }
    final total = response.contentLength >= 0 ? response.contentLength : null;
    var received = 0;
    var reported = 0;
    final counted = response
        .timeout(const Duration(seconds: 60))
        .transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, sink) {
              received += chunk.length;
              if (received - reported >= 256 * 1024) {
                reported = received;
                send.send(['progress', received, total]);
              }
              sink.add(chunk);
            },
            handleDone: (sink) {
              send.send(['installing', received, total]);
              sink.close();
            },
          ),
        );
    final converter = await convertKaikkiGzip(
      counted,
      partPath,
      language: args[4] as String,
      languageName: args[5] as String,
      version: DateTime.now().toUtc().toIso8601String().substring(0, 10),
    );
    if (converter.entries == 0) {
      File(partPath).deleteSync();
      send.send(['error', 'The download contained no dictionary entries.']);
      return;
    }
    File(partPath).renameSync(finalPath);
    send.send(['done']);
  } on TimeoutException {
    _cleanup(partPath);
    send.send(['error', 'The download stalled. Check your connection.']);
  } on SocketException catch (error) {
    _cleanup(partPath);
    send.send(['error', 'No connection (${error.message}).']);
  } on HttpException catch (error) {
    _cleanup(partPath);
    send.send(['error', 'Download failed (${error.message}).']);
  } catch (error) {
    _cleanup(partPath);
    send.send(['error', 'Install failed: $error']);
  } finally {
    client.close(force: true);
  }
}

void _cleanup(String partPath) {
  try {
    final file = File(partPath);
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // Nothing to clean.
  }
}
