import 'dart:async';
import 'dart:io';

import 'package:bookmunity/features/dictionary/dictionary_service.dart';
import 'package:bookmunity/features/dictionary/pack/pack_installer.dart';
import 'package:bookmunity/features/dictionary/pack/pack_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Serves the gzipped fixture like kaikki.org, or stalls / fails on cue.
class _FakeKaikki {
  late HttpServer server;
  final body = gzippedFrenchFixture();
  final stalled = Completer<void>();

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/French.jsonl.gz':
          response.contentLength = body.length;
          response.add(body);
          await response.close();
        case '/stall.jsonl.gz':
          response.contentLength = body.length * 10;
          response.add(body.sublist(0, 10));
          await response.flush();
          await stalled.future;
          await response.close();
        default:
          response.statusCode = HttpStatus.notFound;
          await response.close();
      }
    });
  }

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${server.port}/$path');

  Future<void> stop() async {
    if (!stalled.isCompleted) stalled.complete();
    await server.close(force: true);
  }
}

void main() {
  late _FakeKaikki kaikki;
  late PackStore store;

  setUp(() async {
    kaikki = _FakeKaikki();
    await kaikki.start();
    store = temporaryStore()..directory.createSync(recursive: true);
  });

  tearDown(() async {
    await kaikki.stop();
    deleteStore(store);
  });

  Future<PackInstallJob> install(String path) => PackInstallJob.start(
    uri: kaikki.uri(path),
    partPath: store.partFile('fr').path,
    finalPath: store.packFile('fr').path,
    language: 'fr',
    languageName: 'French',
  );

  test('downloads, converts and installs a pack, then deletes it', () async {
    final job = await install('French.jsonl.gz');
    final phases = <PackInstallPhase>[];
    job.progress.listen((progress) => phases.add(progress.phase));
    await job.done;

    expect(phases, contains(PackInstallPhase.installing));
    expect(store.isInstalled('fr'), isTrue);
    expect(store.installed().keys, ['fr']);
    expect(store.partFile('fr').existsSync(), isFalse);

    final service = DictionaryService(store);
    final found = await service.lookup(
      'mangeons',
      language: const LookupLanguage('fr'),
    );
    expect(found, isA<DictionaryFound>());
    expect(found.source.language, 'fr');
    expect((found as DictionaryFound).entry.word, 'manger');

    await store.delete('fr');
    expect(store.isInstalled('fr'), isFalse);
    expect(store.installed(), isEmpty);
    expect(store.pack('fr'), isNull);
  });

  test('cancel stops the download and leaves no files', () async {
    final job = await install('stall.jsonl.gz');
    await job.progress.first.timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          const PackInstallProgress(PackInstallPhase.downloading, 0, null),
    );
    await job.cancel();
    await expectLater(job.done, throwsA(isA<PackInstallCancelled>()));
    expect(store.isInstalled('fr'), isFalse);
    expect(store.partFile('fr').existsSync(), isFalse);
  });

  test('reports server errors', () async {
    final job = await install('missing.jsonl.gz');
    await expectLater(
      job.done,
      throwsA(
        isA<PackInstallException>().having(
          (error) => error.message,
          'message',
          contains('404'),
        ),
      ),
    );
    expect(store.isInstalled('fr'), isFalse);
  });
}
