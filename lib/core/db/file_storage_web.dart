Future<void> deleteStoredFile(String path) async {}

/// Web keeps no files on disk; paths are left as they are.
Future<({String? filePath, String? coverPath})> resolveStoredFiles(
  String fileHash,
  String? filePath,
  String? coverPath,
) async => (filePath: filePath, coverPath: coverPath);
