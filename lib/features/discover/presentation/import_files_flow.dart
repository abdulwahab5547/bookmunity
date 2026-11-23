import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/import/epub_import_service.dart';
import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';

/// "Add book": picks EPUB or PDF files and imports them. PDFs are
/// converted on the device behind a progress dialog that can be cancelled;
/// a cancelled PDF is skipped. Scanned PDFs get a short explanation.
Future<List<ImportResult>> pickAndImportBooks(
  BuildContext context,
  EpubImportService service,
) async {
  final files = await service.pickFiles();
  final results = <ImportResult>[];
  for (final file in files) {
    if (!context.mounted) break;
    if (!file.name.toLowerCase().endsWith('.pdf')) {
      results.add(await service.importFile(file));
      continue;
    }
    final result = await _importPdf(context, service, file);
    if (result == null) continue;
    results.add(result);
    if (result.scannedPdf && !result.duplicate && context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Scanned PDF'),
          content: Text(
            '“${result.title}” has no text layer, so each page was added as '
            'an image. You can read it, but text size, search and '
            'highlights will not work.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
  return results;
}

Future<ImportResult?> _importPdf(
  BuildContext context,
  EpubImportService service,
  PlatformFile file,
) async {
  final progress = ValueNotifier<(double, String)>((0, 'Opening PDF'));
  final cancel = PdfConversionCancelToken();
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: _ConversionDialog(
        name: file.name,
        progress: progress,
        onCancel: cancel.cancel,
      ),
    ),
  );
  try {
    return await service.importFile(
      file,
      cancelToken: cancel,
      onProgress: (fraction, stage) => progress.value = (fraction, stage),
    );
  } on PdfConversionCancelled {
    return null;
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    await dialog;
    progress.dispose();
  }
}

class _ConversionDialog extends StatelessWidget {
  const _ConversionDialog({
    required this.name,
    required this.progress,
    required this.onCancel,
  });

  final String name;
  final ValueNotifier<(double, String)> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Converting PDF'),
      content: ValueListenableBuilder(
        valueListenable: progress,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 14),
            BrutalProgressBar(value: value.$1, color: BrutalColors.blue),
            const SizedBox(height: 8),
            Text(value.$2, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              'The PDF is rebuilt as an EPUB on your phone so it reflows like '
              'any other book.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: onCancel, child: const Text('Cancel'))],
    );
  }
}
