import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../../../design/formatters.dart';
import '../../../providers/app_providers.dart';
import '../../achievements/data/achievement_service.dart';
import '../../achievements/domain/badges.dart';
import '../data/community_models.dart';
import '../data/community_providers.dart';
import '../data/social_models.dart';
import '../data/social_providers.dart';
import 'community_widgets.dart';
import 'friend_profile_screen.dart';

/// The reader's public shelf. For the user's own profile, falls back to
/// the books on this device while the cloud library is empty (it is
/// written by the sync feature).
final profileShelfProvider = Provider.autoDispose
    .family<AsyncValue<List<ShelfEntry>>, String>((ref, uid) {
      final cloud = ref.watch(shelfProvider(uid));
      final isMe = ref.watch(communityRepositoryProvider)?.uid == uid;
      if (!isMe || cloud.valueOrNull?.isNotEmpty == true) return cloud;
      if (cloud.isLoading) return cloud;
      return ref.watch(booksProvider).whenData(localShelf);
    });

List<ShelfEntry> localShelf(List<Book> books) => [
  for (final book in books)
    ShelfEntry(
      bookKey: book.bookKey,
      title: book.title,
      author: book.author,
      shelf: Shelf.parse(book.shelf),
      progress: book.progressPercent,
      coverPath: book.coverPath,
      addedAt: book.addedAt,
      finishedAt: book.finishedAt,
      updatedAt: book.lastOpenedAt,
    ),
];

/// Badge ids to show; own profile falls back to this device's unlocks.
final profileBadgesProvider = Provider.autoDispose
    .family<List<String>, String>((ref, uid) {
      final cloud =
          ref.watch(badgeUnlocksOfProvider(uid)).valueOrNull ?? const [];
      final isMe = ref.watch(communityRepositoryProvider)?.uid == uid;
      if (cloud.isNotEmpty || !isMe) {
        return [for (final badge in cloud) badge.badgeId];
      }
      final local = ref.watch(badgeUnlocksProvider).valueOrNull ?? const [];
      return [for (final unlock in local) unlock.badgeId];
    });

/// Goodreads-style profile: header, numbers, shelves, badges, ratings,
/// quotes and updates.
class ReaderProfileView extends ConsumerWidget {
  const ReaderProfileView({
    required this.profile,
    this.avatar,
    this.action,
    super.key,
  });

  final Profile profile;

  /// Replaces the plain avatar (own profile adds an edit badge).
  final Widget? avatar;

  /// Friend button under the header (other readers).
  final Widget? action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = profile.uid;
    final shelf = ref.watch(profileShelfProvider(uid));
    final grouped = ShelfEntry.group(shelf.valueOrNull ?? const []);
    final stats = ref.watch(readerStatsProvider(uid)).valueOrNull;
    final badges = ref.watch(profileBadgesProvider(uid));
    final first = profile.displayName.split(' ').first;
    final isMe = ref.watch(communityRepositoryProvider)?.uid == uid;
    final whose = isMe ? 'Your' : '$first’s';

    return RefreshIndicator(
      onRefresh: () async {
        ref.read(communityRevisionProvider.notifier).state++;
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          ProfileHeader(profile: profile, avatar: avatar),
          if (action != null) ...[const SizedBox(height: 16), action!],
          const SizedBox(height: 20),
          _StatsGrid(
            items: [
              (
                '${grouped[Shelf.finished]!.length > profile.booksFinished ? grouped[Shelf.finished]!.length : profile.booksFinished}',
                'Read',
              ),
              ('${stats?.ratings ?? '–'}', 'Ratings'),
              (
                stats == null || stats.ratings == 0
                    ? '–'
                    : stats.averageRating.toStringAsFixed(1),
                'Avg rating',
              ),
              ('${stats?.friends ?? '–'}', 'Friends'),
              ('${profile.currentStreak}', 'Day streak'),
              ('${badges.length > profile.badgeCount ? badges.length : profile.badgeCount}', 'Badges'),
            ],
          ),
          const SizedBox(height: 24),
          SectionLabel('$whose bookshelves'),
          if (shelf.isLoading && !shelf.hasValue)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (shelf.hasError)
            Text(
              socialErrorMessage(shelf.error!),
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            for (final entry in [
              Shelf.currentlyReading,
              Shelf.finished,
              Shelf.wantToRead,
            ])
              _ShelfRow(
                shelf: entry,
                entries: grouped[entry]!,
                owner: profile.displayName,
              ),
          const SizedBox(height: 8),
          SectionLabel('Badges (${badges.length})'),
          _BadgeWrap(badgeIds: badges),
          const SizedBox(height: 24),
          _ReviewsPreview(uid: uid, name: profile.displayName),
          const SizedBox(height: 24),
          _PostsPreview(
            title: 'Quotes',
            query: FeedQuery.author(uid, type: PostType.quote),
            empty: 'No quotes shared yet.',
            limit: 2,
          ),
          const SizedBox(height: 24),
          _PostsPreview(
            title: 'Updates',
            query: FeedQuery.author(uid),
            empty: 'No updates yet.',
            limit: 3,
          ),
        ],
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.items});

  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Three per row on phones, six on wide screens.
        final perRow = constraints.maxWidth >= 560 ? 6 : 3;
        const gap = 8.0;
        final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final (value, label) in items)
              SizedBox(
                width: width,
                child: BrutalCard(
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 4,
                  ),
                  child: Column(
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(value, style: theme.textTheme.titleLarge),
                      ),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ShelfRow extends StatelessWidget {
  const _ShelfRow({
    required this.shelf,
    required this.entries,
    required this.owner,
  });

  final Shelf shelf;
  final List<ShelfEntry> entries;
  final String owner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${shelf.label} (${entries.length})',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (entries.isNotEmpty)
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ShelfScreen(
                        title: '$owner · ${shelf.label}',
                        entries: entries,
                      ),
                    ),
                  ),
                  child: const Text('See all'),
                ),
            ],
          ),
          if (entries.isEmpty)
            Text('Nothing on this shelf.', style: theme.textTheme.bodySmall)
          else
            SizedBox(
              height: shelf == Shelf.currentlyReading ? 138 : 120,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: entries.length.clamp(0, 20),
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return SizedBox(
                    width: 72,
                    child: InkWell(
                      borderRadius: BrutalTokens.smallBorderRadius,
                      onTap: () => openBook(context, entry.book),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          BookThumb(
                            book: entry.book,
                            coverPath: entry.coverPath,
                            width: 72,
                            height: 108,
                          ),
                          if (shelf == Shelf.currentlyReading) ...[
                            const SizedBox(height: 6),
                            BrutalProgressBar(
                              value: entry.progress / 100,
                              height: 6,
                            ),
                            Text(
                              '${entry.progress.floor()}%',
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// All books on one shelf, with progress.
class ShelfScreen extends StatelessWidget {
  const ShelfScreen({required this.title, required this.entries, super.key});

  final String title;
  final List<ShelfEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: BrutalAppBar(title: title),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return BrutalCard(
            padding: const EdgeInsets.all(12),
            onTap: () => openBook(context, entry.book),
            child: Row(
              children: [
                BookThumb(
                  book: entry.book,
                  coverPath: entry.coverPath,
                  width: 48,
                  height: 72,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      if (entry.author.isNotEmpty)
                        Text(
                          entry.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      const SizedBox(height: 6),
                      if (entry.shelf == Shelf.finished)
                        Text(
                          entry.finishedAt == null
                              ? 'Read'
                              : 'Read ${formatDate(entry.finishedAt!)}',
                          style: theme.textTheme.labelMedium,
                        )
                      else if (entry.shelf == Shelf.currentlyReading)
                        Row(
                          children: [
                            Expanded(
                              child: BrutalProgressBar(
                                value: entry.progress / 100,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${entry.progress.floor()}%',
                              style: theme.textTheme.labelMedium,
                            ),
                          ],
                        )
                      else
                        Text('Want to read', style: theme.textTheme.labelMedium),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BadgeWrap extends StatelessWidget {
  const _BadgeWrap({required this.badgeIds});

  final List<String> badgeIds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badges = [for (final id in badgeIds) ?Badges.byId(id)];
    if (badges.isEmpty) {
      return Text('No badges yet.', style: theme.textTheme.bodySmall);
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final badge in badges)
          Tooltip(
            message: badge.description,
            child: Container(
              padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
              decoration: BoxDecoration(
                color: BrutalColors.yellow,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: theme.colorScheme.outline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(badge.icon, size: 16, color: BrutalColors.ink),
                  const SizedBox(width: 4),
                  Text(
                    badge.title,
                    style: const TextStyle(
                      color: BrutalColors.ink,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ReviewsPreview extends ConsumerWidget {
  const _ReviewsPreview({required this.uid, required this.name});

  final String uid;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final reviews = ref.watch(readerReviewsProvider(uid));
    final items = reviews.valueOrNull ?? const <ReaderReview>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(
          'Ratings and reviews',
          trailing: items.length > 3
              ? TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ReaderReviewsScreen(uid: uid, name: name),
                    ),
                  ),
                  child: const Text('See all'),
                )
              : null,
        ),
        if (reviews.isLoading && !reviews.hasValue)
          const Center(child: CircularProgressIndicator())
        else if (reviews.hasError)
          Text(
            socialErrorMessage(reviews.error!),
            style: theme.textTheme.bodySmall,
          )
        else if (items.isEmpty)
          Text('No ratings yet.', style: theme.textTheme.bodySmall)
        else
          for (final item in items.take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ReviewTile(review: item.review, book: item.book),
            ),
      ],
    );
  }
}

class ReaderReviewsScreen extends ConsumerWidget {
  const ReaderReviewsScreen({required this.uid, required this.name, super.key});

  final String uid;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: BrutalAppBar(title: '$name · Ratings'),
      body: ref
          .watch(readerReviewsProvider(uid))
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Ratings unavailable',
              message: socialErrorMessage(error),
            ),
            data: (items) => ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) => ReviewTile(
                review: items[index].review,
                book: items[index].book,
              ),
            ),
          ),
    );
  }
}

class _PostsPreview extends ConsumerWidget {
  const _PostsPreview({
    required this.title,
    required this.query,
    required this.empty,
    required this.limit,
  });

  final String title;
  final FeedQuery query;
  final String empty;
  final int limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(feedProvider(query));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(
          title,
          trailing: state.items.length > limit
              ? TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: BrutalAppBar(title: title),
                        body: FeedList(
                          query: query,
                          empty: EmptyState(
                            icon: Icons.dynamic_feed_outlined,
                            title: empty,
                          ),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('See all'),
                )
              : null,
        ),
        if (!state.loaded)
          const Center(child: CircularProgressIndicator())
        else if (state.items.isEmpty)
          Text(
            state.error != null ? socialErrorMessage(state.error!) : empty,
            style: theme.textTheme.bodySmall,
          )
        else
          for (final post in state.items.take(limit))
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: PostCard(key: ValueKey(post.id), post: post),
            ),
      ],
    );
  }
}
