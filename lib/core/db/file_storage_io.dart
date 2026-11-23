import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<void> deleteStoredFile(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}

/// Finds a book's EPUB and cover on this device. Files are stored by hash
/// (`books/<hash>.epub`, `covers/<hash>.jpg`), so the same file serves every
/// account on the device, and absolute paths that went stale (reinstall,
/// iOS container move) are repaired.
Future<({String? filePath, String? coverPath})> resolveStoredFiles(
  String fileHash,
  String? filePath,
  String? coverPath,
) async {
  final directory = await getApplicationDocumentsDirectory();
  Future<String?> find(String? current, String candidate) async {
    if (current != null && await File(current).exists()) return current;
    if (await File(candidate).exists()) return candidate;
    return null;
  }

  final file = await find(filePath, '${directory.path}/books/$fileHash.epub');
  final cover = await find(coverPath, '${directory.path}/covers/$fileHash.jpg');
  return (filePath: file, coverPath: cover);
}
