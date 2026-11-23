import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/brutal_widgets.dart';
import 'dictionaries_screen.dart';
import 'dictionary_providers.dart';
import 'dictionary_service.dart';
import 'language_catalog.dart';
import 'pack/pack_installer.dart';

export 'dictionary_providers.dart'
    show DictionaryQuery, definitionProvider, lookupOverrideProvider;

/// Compact, Kindle-style definition preview shown with a word selection.
class DictionaryPreview extends ConsumerWidget {
  const DictionaryPreview({required this.query, this.onMore, super.key});

  final DictionaryQuery query;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final word = query.word;
    final result = ref.watch(definitionProvider(query));
    return InkWell(
      onTap: onMore,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: result.when(
          loading: () => Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Looking up “$word”…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          error: (error, _) => Text(
            'The dictionary could not be opened.',
            style: theme.textTheme.bodySmall,
          ),
          data: (value) => switch (value) {
            DictionaryFound(:final entries) => _FoundPreview(
              result: value,
              entries: entries,
              showMore: onMore != null,
            ),
            DictionaryNotFound() => Text(
              'No dictionary entry for “$word”'
              '${_languageSuffix(value)}.',
              style: theme.textTheme.bodySmall,
            ),
          },
        ),
      ),
    );
  }

  static String _languageSuffix(DictionaryResult result) {
    final missing = languageByCode(result.missingLanguage);
    if (missing != null) {
      return '. Get the ${missing.name} dictionary from More';
    }
    final language = languageByCode(result.source.language);
    return language == null || language.code == 'en'
        ? ''
        : ' in ${language.name}';
  }
}

class _FoundPreview extends StatelessWidget {
  const _FoundPreview({
    required this.result,
    required this.entries,
    required this.showMore,
  });

  final DictionaryResult result;
  final List<DictionaryEntry> entries;
  final bool showMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = entries.first;
    final meaning = entry.meanings.first;
    final others = entries.skip(1).map((e) => e.word).toSet().toList();
    final languageTag = result.source.language == 'en'
        ? null
        : result.source.language.toUpperCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: entry.word,
                  style: theme.textTheme.titleMedium,
                  children: [
                    if (entry.note != null && entry.word != result.query)
                      TextSpan(
                        text: '  from “${result.query}”',
                        style: theme.textTheme.bodySmall,
                      ),
                    if (languageTag != null)
                      TextSpan(
                        text: '  $languageTag',
                        style: theme.textTheme.labelSmall,
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (showMore)
              Text(
                'More',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '${meaning.partOfSpeech.isEmpty ? '' : '${meaning.partOfSpeech}. '}'
          '${entry.shortDefinition ?? ''}',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
        if (others.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Also: ${others.take(3).join(', ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

Future<void> showDictionarySheet(BuildContext context, DictionaryQuery query) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (context, controller) =>
          DictionaryDetail(query: query, controller: controller),
    ),
  );
}

/// The full definition, with the lookup language switch.
class DictionaryDetail extends ConsumerWidget {
  const DictionaryDetail({
    required this.query,
    required this.controller,
    super.key,
  });

  final DictionaryQuery query;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final result = ref.watch(definitionProvider(query));
    final header = _SheetHeader(query: query);
    return result.when(
      loading: () => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          header,
          const SizedBox(height: 32),
          const Center(child: CircularProgressIndicator()),
        ],
      ),
      error: (error, _) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          header,
          const SizedBox(height: 12),
          Text('The dictionary could not be opened: $error'),
        ],
      ),
      data: (value) {
        final missing = languageByCode(value.missingLanguage);
        return ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          children: [
            header,
            if (missing != null) ...[
              const SizedBox(height: 12),
              _MissingPackBanner(language: missing),
            ],
            const SizedBox(height: 8),
            if (value is DictionaryFound)
              for (final (index, entry) in value.entries.indexed) ...[
                if (index > 0) const Divider(height: 32),
                _EntryView(
                  entry: entry,
                  english: value.source.language == 'en',
                ),
              ]
            else
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'No entry for “${query.word}” in the '
                  '${languageByCode(value.source.language)?.name ?? 'selected'} '
                  'dictionary.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            const SizedBox(height: 20),
            Text(value.source.attribution, style: theme.textTheme.labelSmall),
            if (value is DictionaryFound && value.source.language == 'en')
              _PhoneticCredit(word: value.entry.word),
          ],
        );
      },
    );
  }
}

class _SheetHeader extends ConsumerWidget {
  const _SheetHeader({required this.query});

  final DictionaryQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final language = ref.watch(lookupLanguageProvider(query)).valueOrNull;
    final installed = ref.watch(
      dictionaryPacksProvider.select((state) => state.installed),
    );
    final options = [
      englishLanguage,
      for (final language in downloadableLanguages)
        if (installed.containsKey(language.code)) language,
    ];
    final current = languageByCode(language?.code) ?? englishLanguage;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Dictionary',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Lookup language',
            onSelected: (code) {
              if (code == '_manage') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DictionariesScreen()),
                );
                return;
              }
              ref
                      .read(lookupOverrideProvider(query.bookId ?? 0).notifier)
                      .state =
                  code;
            },
            itemBuilder: (context) => [
              for (final option in options)
                CheckedPopupMenuItem(
                  value: option.code,
                  checked: option.code == current.code,
                  child: Text(option.name),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: '_manage',
                child: Text('Manage dictionaries…'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.translate,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    current.name,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, color: theme.colorScheme.primary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Offers the pack for the book's language when English answered instead.
class _MissingPackBanner extends ConsumerWidget {
  const _MissingPackBanner({required this.language});

  final DictionaryLanguage language;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final task = ref.watch(
      dictionaryPacksProvider.select((state) => state.tasks[language.code]),
    );
    final controller = ref.read(dictionaryPacksProvider.notifier);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This book is in ${language.name}. Showing English until the '
            '${language.name} dictionary is downloaded.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (task != null && task.running)
            PackProgressRow(
              task: task,
              onCancel: () => controller.cancel(language.code),
            )
          else
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                TextButton.icon(
                  onPressed: () => controller.download(language),
                  icon: const Icon(Icons.download, size: 18),
                  label: Text(
                    '${task?.error != null ? 'Retry' : 'Download'} '
                    '${language.name} · ${formatBytes(language.downloadBytes)}',
                  ),
                ),
                if (task?.error != null)
                  Text(
                    task!.error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _EntryView extends ConsumerWidget {
  const _EntryView({required this.entry, required this.english});

  final DictionaryEntry entry;
  final bool english;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final phonetic = english
        ? ref.watch(phoneticProvider(entry.word)).valueOrNull
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(entry.word, style: theme.textTheme.headlineSmall),
        if (phonetic != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(phonetic, style: theme.textTheme.bodySmall),
          ),
        if (entry.note != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              entry.note!,
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        for (final meaning in entry.meanings) ...[
          const SizedBox(height: 16),
          Text(
            meaning.partOfSpeech.isEmpty ? 'Meaning' : meaning.partOfSpeech,
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 6),
          for (final (index, sense) in meaning.senses.take(8).indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      '${index + 1}.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(sense.definition),
                        for (final example in sense.examples)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              '“$example”',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        if (sense.synonyms.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              'Also: ${sense.synonyms.take(5).join(', ')}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (meaning.senses.length > 8)
            Text(
              '${meaning.senses.length - 8} more senses',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ],
    );
  }
}

class _PhoneticCredit extends ConsumerWidget {
  const _PhoneticCredit({required this.word});

  final String word;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phonetic = ref.watch(phoneticProvider(word)).valueOrNull;
    if (phonetic == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        'Pronunciation from dictionaryapi.dev (Wiktionary, CC BY-SA).',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

/// Download progress with a cancel button, shared by the sheet and the
/// Dictionaries screen.
class PackProgressRow extends StatelessWidget {
  const PackProgressRow({
    required this.task,
    required this.onCancel,
    super.key,
  });

  final PackTask task;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final installing = task.phase == PackInstallPhase.installing;
    final label = installing
        ? 'Installing… this can take a minute'
        : task.fraction == null
        ? 'Downloading ${formatBytes(task.received)}'
        : 'Downloading ${(task.fraction! * 100).round()}% · '
              '${formatBytes(task.received)} of ${formatBytes(task.total!)}';
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (installing || task.fraction == null)
                const LinearProgressIndicator()
              else
                BrutalProgressBar(
                  value: task.fraction!,
                  color: theme.colorScheme.primary,
                ),
              const SizedBox(height: 6),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: onCancel, child: const Text('Cancel')),
      ],
    );
  }
}

String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return '${mb >= 10 ? mb.round() : mb.toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}
