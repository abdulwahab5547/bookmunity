// Converts a downloaded kaikki.org .jsonl.gz file into a dictionary pack with
// the same code the app runs on device, and reports how long it took.
//
//   dart run tools/dictionary/convert_kaikki.dart <input.jsonl.gz> <out.db> <code> <Name>
import 'dart:io';

import 'package:bookmunity/features/dictionary/pack/kaikki_converter.dart';

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln(
      'usage: convert_kaikki.dart <input.jsonl.gz> <out.db> <code> <Name>',
    );
    exit(64);
  }
  final watch = Stopwatch()..start();
  final converter = await convertKaikkiGzip(
    File(args[0]).openRead(),
    args[1],
    language: args[2],
    languageName: args[3],
    version: 'local',
  );
  stdout.writeln(
    'lines=${converter.lines} entries=${converter.entries} '
    'forms=${converter.forms} time=${watch.elapsed} '
    'size=${File(args[1]).lengthSync()}',
  );
}
