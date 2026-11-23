import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brutal_widgets.dart';
import '../data/community_models.dart';
import '../data/community_providers.dart';
import '../data/social_providers.dart';
import 'community_widgets.dart';

/// Public page for any book: cover, average rating, reviews and quotes.
/// Works from the book's identity key alone, so it opens for books that are
/// not in the user's library.
class BookPageScreen extends ConsumerWidget {
  const BookPageScreen({required this.book, super.key});

  final BookRef book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final key = book.docKey;
    final reviews = ref.watch(reviewsProvider(key));
    final rating = ref.watch(bookRatingProvider(key)).valueOrNull;
    final quotes = ref.watch(feedProvider(FeedQuery.bookQuotes(key)));
    final title = book.title.isNotEmpty ? book.title : 'Untitled';
    final shown = BookRef(
      bookKey: key,
      title: title,
      author: book.author,
      coverUrl: book.coverUrl,
    );

    return Scaffold(
      appBar: BrutalAppBar(title: title),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(bookRatingProvider(key));
          await ref.read(feedProvider(FeedQuery.bookQuotes(key)).notifier).refresh();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BookThumb(book: shown, width: 96, height: 144),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.headlineSmall),
                      if (book.author.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(book.author, style: theme.textTheme.bodyMedium),
                      ],
                      const SizedBox(height: 12),
                      if (rating == null)
                        const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (rating.count == 0)
                        Text('No ratings yet', style: theme.textTheme.bodySmall)
                      else ...[
                        StarRating(rating: rating.average, size: 20),
                        const SizedBox(height: 4),
                        Text(
                          '${rating.average.toStringAsFixed(2)} avg · '
                          '${rating.count} '
                          '${rating.count == 1 ? 'rating' : 'ratings'}',
                          style: theme.textTheme.labelMedium,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const SectionLabel('Ratings and reviews'),
            reviews.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => Text(
                socialErrorMessage(error),
                style: theme.textTheme.bodySmall,
              ),
              data: (items) => items.isEmpty
                  ? Text(
                      'No reviews yet. Open the book from your library to '
                      'rate it.',
                      style: theme.textTheme.bodySmall,
                    )
                  : Column(
                      children: [
                        for (final review in items)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: ReviewTile(review: review),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            const SectionLabel('Quotes'),
            if (!quotes.loaded)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (quotes.items.isEmpty)
              Text(
                quotes.error != null
                    ? socialErrorMessage(quotes.error!)
                    : 'No quotes shared from this book yet.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              for (final post in quotes.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: PostCard(key: ValueKey(post.id), post: post),
                ),
              if (quotes.hasMore)
                Center(
                  child: TextButton(
                    onPressed: quotes.loading
                        ? null
                        : () => ref
                              .read(
                                feedProvider(FeedQuery.bookQuotes(key)).notifier,
                              )
                              .loadMore(),
                    child: const Text('More quotes'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
