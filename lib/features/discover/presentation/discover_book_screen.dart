import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../../../providers/app_providers.dart';
import '../../reader/presentation/reader_screen.dart';
import '../data/discover_models.dart';
import '../data/discover_providers.dart';
import 'discover_widgets.dart';

/// A free book: cover, details, and download → import → read.
class DiscoverBookScreen extends ConsumerWidget {
  const DiscoverBookScreen({required this.book, super.key});

  final DiscoverBook book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final details = ref.watch(bookDetailsProvider(book));
    final full = details.valueOrNull ?? book;
    final theme = Theme.of(context);
    final languages = full.languages
        .map((code) => code.toUpperCase())
        .join(', ');
    final facts = [
      full.source.label,
      if (full.year != null) '${full.year}',
      if (languages.isNotEmpty) languages,
    ];

    return Scaffold(
      appBar: const BrutalAppBar(title: 'Free book'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 112,
                child: DiscoverCover(title: full.title, url: full.coverUrl),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(full.title, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(full.authorLine, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 10),
                    Text(facts.join(' · '), style: theme.textTheme.bodySmall),
                    if (full.summary != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        full.summary!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _DownloadPanel(book: full, loadingDetails: details.isLoading),
          if (full.alsoFrom.isNotEmpty) ...[
            const SizedBox(height: 20),
            SectionLabel('Also free from'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final other in full.alsoFrom)
                  BrutalChip(
                    label: other.source.label,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DiscoverBookScreen(book: other),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (full.description != null) ...[
            const SizedBox(height: 24),
            const SectionLabel('About this book'),
            Text(full.description!, style: theme.textTheme.bodyMedium),
          ] else if (details.isLoading) ...[
            const SizedBox(height: 24),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (full.subjects.isNotEmpty) ...[
            const SizedBox(height: 24),
            const SectionLabel('Subjects'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final subject in full.subjects)
                  DiscoverTag(label: subject),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DownloadPanel extends ConsumerWidget {
  const _DownloadPanel({required this.book, required this.loadingDetails});

  final DiscoverBook book;
  final bool loadingDetails;

  Future<void> _read(BuildContext context, WidgetRef ref, int bookId) async {
    final database = await ref.read(databaseProvider.future);
    final row = await database.watchBook(bookId).first;
    if (row == null || !context.mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ReaderScreen(book: row)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final downloads = ref.read(downloadsProvider.notifier);
    final state = ref.watch(downloadsProvider)[book.key];
    final owned = ref.watch(libraryIndexProvider).find(book);
    final option = book.download;

    Widget readButton(int id) => BrutalPressable(
      onPressed: () => _read(context, ref, id),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(Icons.menu_book), SizedBox(width: 8), Text('Read now')],
      ),
    );

    Widget panel(List<Widget> children, {Color? color}) => BrutalCard(
      backgroundColor: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );

    // Download in progress or finished in this session.
    if (state != null) {
      switch (state.phase) {
        case DownloadPhase.downloading:
        case DownloadPhase.converting:
        case DownloadPhase.importing:
          final fraction = state.fraction;
          final label = switch (state.phase) {
            DownloadPhase.downloading =>
              state.total == null
                  ? 'Downloading… ${formatBytes(state.received)}'
                  : 'Downloading… ${formatBytes(state.received)} of '
                        '${formatBytes(state.total!)}',
            DownloadPhase.converting => '${state.stage ?? 'Converting PDF'}…',
            _ => 'Adding to your library…',
          };
          return panel([
            Text(label, style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            fraction == null
                ? const LinearProgressIndicator(minHeight: 6)
                : BrutalProgressBar(value: fraction, color: BrutalColors.blue),
            if (state.phase == DownloadPhase.converting) ...[
              const SizedBox(height: 8),
              Text(
                'PDFs are converted to EPUB on your phone. Large ones take a '
                'minute.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: state.phase == DownloadPhase.importing
                  ? null
                  : () => downloads.cancel(book),
              icon: const Icon(Icons.close),
              label: const Text('Cancel'),
            ),
          ]);
        case DownloadPhase.done:
          return panel(color: BrutalColors.green.withValues(alpha: 0.35), [
            Text(
              state.duplicate
                  ? 'Already in your library'
                  : 'Added to your library',
              style: theme.textTheme.titleSmall?.copyWith(
                color: BrutalColors.ink,
              ),
            ),
            if (state.scanned) ...[
              const SizedBox(height: 6),
              const Text(
                'This PDF is a scan without text, so each page is shown as '
                'an image. Text size and highlights are not available.',
              ),
            ],
            const SizedBox(height: 12),
            if (state.bookId != null) readButton(state.bookId!),
          ]);
        case DownloadPhase.failed:
          return panel([
            Row(
              children: [
                Icon(Icons.error_outline, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Download failed',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(state.error ?? '', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            BrutalPressable(
              onPressed: () => downloads.start(book),
              child: const Text('Try again'),
            ),
          ]);
      }
    }

    if (owned != null && owned.filePath != null) {
      return panel([
        Row(
          children: [
            const Icon(Icons.check_circle, color: BrutalColors.green),
            const SizedBox(width: 8),
            Expanded(
              child: Text('In your library', style: theme.textTheme.titleSmall),
            ),
          ],
        ),
        const SizedBox(height: 12),
        readButton(owned.id),
      ]);
    }

    if (option == null) {
      if (loadingDetails) {
        return panel([
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Looking for a free copy…',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ]);
      }
      return panel([
        Text('No free download', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(
          'The Internet Archive only lends this edition, so it cannot be '
          'downloaded here. Try searching for another edition.',
          style: theme.textTheme.bodySmall,
        ),
      ]);
    }

    final size = option.sizeBytes == null
        ? ''
        : ' · ${formatBytes(option.sizeBytes!)}';
    return panel([
      if (owned != null) ...[
        Text(
          'In your library, but not on this device',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          'Downloading it again keeps your progress and highlights.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
      ],
      BrutalPressable(
        onPressed: () => downloads.start(book),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download),
            const SizedBox(width: 8),
            Flexible(child: Text('Download ${option.format.label}$size')),
          ],
        ),
      ),
      if (option.format == BookFormat.pdf) ...[
        const SizedBox(height: 8),
        Text(
          'Only a PDF scan is free. It is converted to EPUB on your phone; '
          'old scans may contain recognition errors.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    ]);
  }
}
