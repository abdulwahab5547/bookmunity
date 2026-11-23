// Downloads and installs one language pack with the app's installer (the
// same isolate, download and conversion code), for checking the live
// kaikki.org URLs.
//
//   dart run tools/dictionary/install_pack.dart <code> <output-dir>
import 'dart:io';

import 'package:bookmunity/features/dictionary/language_catalog.dart';
import 'package:bookmunity/features/dictionary/pack/pack_installer.dart';

Future<void> main(List<String> args) async {
  final language = args.length == 2 ? languageByCode(args[0]) : null;
  if (language == null || language.code == 'en') {
    stderr.writeln('usage: install_pack.dart <code> <output-dir>');
    stderr.writeln(
      'codes: ${downloadableLanguages.map((l) => l.code).join(' ')}',
    );
    exit(64);
  }
  final directory = Directory(args[1])..createSync(recursive: true);
  final watch = Stopwatch()..start();
  final job = await PackInstallJob.start(
    uri: language.downloadUri,
    partPath: '${directory.path}/${language.code}.db.part',
    finalPath: '${directory.path}/${language.code}.db',
    language: language.code,
    languageName: language.name,
  );
  var last = -1;
  job.progress.listen((progress) {
    final percent = ((progress.fraction ?? 0) * 100).floor();
    if (progress.phase == PackInstallPhase.installing) {
      stdout.writeln(
        'downloaded ${progress.received} bytes in ${watch.elapsed}',
      );
    } else if (percent ~/ 10 != last) {
      last = percent ~/ 10;
      stdout.writeln('$percent%');
    }
  });
  await job.done;
  final size = File('${directory.path}/${language.code}.db').lengthSync();
  stdout.writeln('installed ${language.name}: $size bytes in ${watch.elapsed}');
}
