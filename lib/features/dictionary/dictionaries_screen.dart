import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/brutal_theme.dart';
import '../../design/brutal_widgets.dart';
import 'dictionary_preferences.dart';
import 'dictionary_providers.dart';
import 'dictionary_view.dart';
import 'language_catalog.dart';

/// Settings > Dictionaries: the built-in English dictionary, the lookup
/// language, and optional language packs to download or remove.
class DictionariesScreen extends ConsumerWidget {
  const DictionariesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final packs = ref.watch(dictionaryPacksProvider);
    final preferences = ref.watch(dictionaryPreferencesProvider);
    final installedLanguages = [
      for (final language in downloadableLanguages)
        if (packs.installed.containsKey(language.code)) language,
    ];

    return Scaffold(
      appBar: const BrutalAppBar(title: 'Dictionaries'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          BrutalCard(
            child: Row(
              children: [
                const Icon(Icons.menu_book_outlined),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('English', style: theme.textTheme.titleMedium),
                      Text(
                        'Built in · WordNet 3.1 · works offline',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const _StatusPill(label: 'Built in'),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const SectionLabel('Look words up in'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              BrutalChip(
                label: 'Book’s language',
                selected: preferences.lookupLanguage == null,
                onPressed: () => ref
                    .read(dictionaryPreferencesProvider.notifier)
                    .setLookupLanguage(null),
              ),
              for (final language in [englishLanguage, ...installedLanguages])
                BrutalChip(
                  label: language.name,
                  selected: preferences.lookupLanguage == language.code,
                  onPressed: () => ref
                      .read(dictionaryPreferencesProvider.notifier)
                      .setLookupLanguage(language.code),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'With “Book’s language”, words are looked up in the language the '
            'book declares, using English when that dictionary is not '
            'downloaded.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          const SectionLabel('More languages'),
          for (final language in downloadableLanguages) ...[
            _LanguageTile(
              language: language,
              installedBytes: packs.installed[language.code],
              task: packs.tasks[language.code],
              chosenElsewhere:
                  preferences.languages.contains(language.code) &&
                  !packs.installed.containsKey(language.code),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 8),
          Text(
            'Language packs are English Wiktionary definitions from '
            'kaikki.org (CC BY-SA 4.0 and GFDL). They download once, are '
            'prepared on this device, and then work offline. Use Wi-Fi for '
            'the larger ones.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _LanguageTile extends ConsumerWidget {
  const _LanguageTile({
    required this.language,
    required this.installedBytes,
    required this.task,
    required this.chosenElsewhere,
  });

  final DictionaryLanguage language;
  final int? installedBytes;
  final PackTask? task;

  /// Chosen on another device (synced) but not downloaded here.
  final bool chosenElsewhere;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(dictionaryPacksProvider.notifier);
    final installed = installedBytes != null;
    final running = task != null && task!.running;
    final subtitle = installed
        ? '${formatBytes(installedBytes!)} on this device'
        : chosenElsewhere
        ? 'Not on this device · ${formatBytes(language.downloadBytes)} download'
        : '${formatBytes(language.downloadBytes)} download';

    return BrutalCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      language.nativeName == language.name
                          ? language.name
                          : '${language.name} · ${language.nativeName}',
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (installed) ...[
                const _StatusPill(label: 'Installed'),
                IconButton(
                  tooltip: 'Delete ${language.name} dictionary',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmDelete(context, controller),
                ),
              ] else if (!running)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: BrutalPressable(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    onPressed: () => controller.download(language),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.download),
                        const SizedBox(width: 6),
                        Text(task?.error != null ? 'Retry' : 'Download'),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 8),
            PackProgressRow(
              task: task!,
              onCancel: () => controller.cancel(language.code),
            ),
          ] else if (task?.error != null) ...[
            const SizedBox(height: 6),
            Text(
              task!.error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    DictionaryPacksController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete the ${language.name} dictionary?'),
        content: Text(
          'Frees ${formatBytes(installedBytes ?? 0)}. You can download it '
          'again at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.delete(language.code);
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: BrutalColors.green,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline,
          width: 1.2,
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: BrutalColors.ink,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}
