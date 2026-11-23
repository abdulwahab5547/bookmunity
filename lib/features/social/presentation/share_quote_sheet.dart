import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../data/community_models.dart';
import '../data/social_providers.dart';

/// What the reader chose in [showShareQuoteSheet].
class QuoteShare {
  const QuoteShare({required this.note, required this.visibility});

  final String note;
  final PostVisibility visibility;
}

/// Asks for an optional note and who can see the quote.
Future<QuoteShare?> showShareQuoteSheet(
  BuildContext context, {
  required String quote,
  String note = '',
}) => showModalBottomSheet<QuoteShare>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _ShareQuoteSheet(quote: quote, note: note),
);

/// Full flow used by the reader and the highlights list: sheet, post,
/// confirmation.
Future<void> shareHighlightAsQuote(
  BuildContext context,
  WidgetRef ref, {
  required Book book,
  required Highlight highlight,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (ref.read(myProfileProvider).valueOrNull == null) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Sign in and choose a username to share quotes.'),
      ),
    );
    return;
  }
  final choice = await showShareQuoteSheet(
    context,
    quote: highlight.selectedText,
    note: highlight.note ?? '',
  );
  if (choice == null) return;
  try {
    final posted = await ref
        .read(socialActivityProvider)
        .shareQuote(
          book: book,
          quote: highlight.selectedText,
          note: choice.note,
          chapter: highlight.chapterTitle ?? '',
          visibility: choice.visibility,
        );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          posted ? 'Quote shared to Community.' : 'Quote not shared.',
        ),
      ),
    );
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(socialErrorMessage(error))));
  }
}

class _ShareQuoteSheet extends StatefulWidget {
  const _ShareQuoteSheet({required this.quote, required this.note});

  final String quote;
  final String note;

  @override
  State<_ShareQuoteSheet> createState() => _ShareQuoteSheetState();
}

class _ShareQuoteSheetState extends State<_ShareQuoteSheet> {
  late final _note = TextEditingController(text: widget.note);
  var _visibility = PostVisibility.public;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final long = widget.quote.length > CommunityLimits.quote;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Share as quote', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BrutalTokens.smallBorderRadius,
                border: const Border(
                  left: BorderSide(color: BrutalColors.yellow, width: 4),
                ),
              ),
              child: Text(
                '“${widget.quote}”',
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontFamily: 'serif',
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            if (long) ...[
              const SizedBox(height: 6),
              Text(
                'Long passages are shortened to '
                '${CommunityLimits.quote} characters.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              maxLines: 4,
              minLines: 2,
              maxLength: CommunityLimits.text,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Your note (optional)',
                hintText: 'Why does this passage stay with you?',
              ),
            ),
            const SizedBox(height: 4),
            Text('Who can see it', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            SegmentedButton<PostVisibility>(
              segments: [
                for (final value in PostVisibility.values)
                  ButtonSegment(
                    value: value,
                    label: Text(value.label),
                    icon: Icon(
                      value == PostVisibility.public
                          ? Icons.public
                          : Icons.group_outlined,
                    ),
                  ),
              ],
              selected: {_visibility},
              showSelectedIcon: false,
              onSelectionChanged: (value) =>
                  setState(() => _visibility = value.first),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: BrutalPressable(
                onPressed: () => Navigator.pop(
                  context,
                  QuoteShare(note: _note.text, visibility: _visibility),
                ),
                backgroundColor: BrutalColors.blue,
                foregroundColor: Colors.white,
                child: const Text('Share'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
