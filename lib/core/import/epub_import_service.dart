import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:file_picker/file_picker.dart';

import '../db/app_database.dart';
import 'epub_metadata_extractor.dart';
import 'import_storage.dart';

class ImportResult {
  const ImportResult({
    required this.title,
    required this.duplicate,
    this.reattached = false,
  });

  final String title;
  final bool duplicate;

  /// The file was attached to a book already in the library (restored from
  /// the cloud without its file), keeping its progress and highlights.
  final bool reattached;
}

class EpubImportService {
  EpubImportService(this.database);

  final AppDatabase database;

  Future<List<ImportResult>> pickAndImport() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['epub'],
      withData: true,
    );
    if (result == null) return const [];

    final imported = <ImportResult>[];
    for (final selected in result.files) {
      imported.add(await importFile(selected));
    }
    return imported;
  }

  Future<ImportResult> importFile(PlatformFile source) async {
    return importBytes(await readPlatformFile(source), filename: source.name);
  }

  /// Imports an EPUB held in memory, e.g. downloaded from a public library
  /// or converted from a PDF. [sourceUrl] is kept so the book can be
  /// downloaded again later.
  Future<ImportResult> importBytes(
    List<int> bytes, {
    String? filename,
    String? sourceUrl,
  }) async {
    final hash = sha256.convert(bytes).toString();
    final existing = await database.findBookByHash(hash);
    if (existing != null && !_needsFile(existing)) {
      return ImportResult(title: existing.title, duplicate: true);
    }

    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((file) => file.name).toSet();
    if (!names.contains('META-INF/container.xml')) {
      throw const FormatException('NOT A VALID EPUB.');
    }
    if (names.contains('META-INF/rights.xml') ||
        names.contains('META-INF/encryption.xml')) {
      throw const FormatException('DRM PROTECTED. CANNOT OPEN.');
    }

    final metadata = await _extractMetadata(archive, filename);
    final destination = await writeBookFile(hash, bytes);
    String? coverPath;
    if (metadata.coverBytes != null) {
      coverPath = await writeCoverFile(hash, 'jpg', metadata.coverBytes!);
    }

    final target = await _reattachTarget(existing, metadata.bookKey);
    if (target != null) {
      return _reattach(target, destination, hash, coverPath, sourceUrl);
    }

    final now = DateTime.now();
    await database.addBook(
      BooksCompanion.insert(
        title: metadata.title,
        author: Value(metadata.author),
        filePath: Value(destination),
        fileHash: Value(hash),
        bookKey: Value(metadata.bookKey),
        addedAt: now,
        coverPath: Value(coverPath),
        genre: Value(metadata.genre),
        sourceUrl: Value(sourceUrl),
      ),
    );
    return ImportResult(title: metadata.title, duplicate: false);
  }

  Future<EpubMetadata> _extractMetadata(Archive archive, String? filename) {
    return Isolate.run(
      () => const EpubMetadataExtractor().extract(archive, filename: filename),
    );
  }

  Future<void> refreshMetadata(Book book) async {
    final filePath = book.filePath;
    final fileHash = book.fileHash;
    // Not on this device: nothing to read metadata from.
    if (filePath == null || fileHash == null) return;
    final bytes = await readStoredBook(filePath);
    final archive = ZipDecoder().decodeBytes(bytes);
    final metadata = await _extractMetadata(archive, filePath);
    String? coverPath;
    if (metadata.coverBytes != null) {
      coverPath = await writeCoverFile(fileHash, 'jpg', metadata.coverBytes!);
    }
    await database.updateMetadata(
      book: book,
      title: metadata.title,
      author: metadata.author,
      bookKey: metadata.bookKey,
      coverPath: coverPath ?? book.coverPath,
      genre: metadata.genre,
    );
  }

  Future<int> refreshAllMetadata() async {
    final books = await database.getBooks();
    var refreshed = 0;
    for (final book in books) {
      try {
        await refreshMetadata(book);
        refreshed++;
      } on FormatException {
        // Keep a malformed book available; its reading state is not changed.
      }
    }
    return refreshed;
  }

  // ------------------------------------------------- re-attach (cloud sync)
  //
  // A library restored from the cloud has rows without files. Importing the
  // same book again attaches the file to that row (matched by hash, else by
  // bookKey) instead of adding a duplicate, so progress, highlights and
  // notes are kept. See docs/cloud-data.md.

  bool _needsFile(Book book) => book.deleted || book.filePath == null;

  Future<Book?> _reattachTarget(Book? sameHash, String bookKey) async =>
      sameHash ?? await database.findBookMissingFile(bookKey);

  Future<ImportResult> _reattach(
    Book target,
    String filePath,
    String hash,
    String? coverPath,
    String? sourceUrl,
  ) async {
    await database.attachBookFile(
      id: target.id,
      filePath: filePath,
      fileHash: hash,
      coverPath: coverPath,
      sourceUrl: sourceUrl,
    );
    return ImportResult(
      title: target.title,
      duplicate: false,
      reattached: true,
    );
  }

  /// "Import file" on a book that is not on this device.
  Future<ImportResult?> pickAndReattach(Book book) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
      withData: true,
    );
    final selected = result?.files.firstOrNull;
    if (selected == null) return null;
    return reattachBytes(
      book,
      await readPlatformFile(selected),
      filename: selected.name,
    );
  }

  /// Attaches [bytes] to [book] even if the file's metadata gives a
  /// different key (another edition, an updated download).
  Future<ImportResult> reattachBytes(
    Book book,
    List<int> bytes, {
    String? filename,
    String? sourceUrl,
  }) async {
    final hash = sha256.convert(bytes).toString();
    final owner = await database.findBookByHash(hash);
    if (owner != null && owner.id != book.id && !_needsFile(owner)) {
      return ImportResult(title: owner.title, duplicate: true);
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((file) => file.name).toSet();
    if (!names.contains('META-INF/container.xml')) {
      throw const FormatException('NOT A VALID EPUB.');
    }
    if (names.contains('META-INF/rights.xml') ||
        names.contains('META-INF/encryption.xml')) {
      throw const FormatException('DRM PROTECTED. CANNOT OPEN.');
    }
    final metadata = await _extractMetadata(archive, filename);
    final destination = await writeBookFile(hash, bytes);
    String? coverPath;
    if (metadata.coverBytes != null) {
      coverPath = await writeCoverFile(hash, 'jpg', metadata.coverBytes!);
    }
    if (owner != null && owner.id != book.id) {
      // A deleted or file-less row holds this hash; free it.
      await database.releaseFileHash(owner.id);
    }
    return _reattach(book, destination, hash, coverPath, sourceUrl);
  }
}
