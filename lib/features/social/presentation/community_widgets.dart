import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/book_cover.dart';
import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../../../design/formatters.dart';
import '../../achievements/domain/badges.dart';
import '../data/community_models.dart';
import '../data/community_providers.dart';
import '../data/social_models.dart';
import '../data/social_providers.dart';
import 'book_page_screen.dart';
import 'friend_profile_screen.dart';
import 'post_detail_screen.dart';
import 'user_avatar.dart';

const starColor = Color(0xFFE0A526);

/// "now", "5m", "3h", "2d", then a date.
String timeAgo(DateTime? value, {DateTime? now}) {
  if (value == null) return 'now';
  final diff = (now ?? DateTime.now()).difference(value);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inHours < 1) return '${diff.inMinutes}m';
  if (diff.inDays < 1) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return formatDate(value);
}

void openProfile(BuildContext context, String uid) => Navigator.of(
  context,
).push(MaterialPageRoute(builder: (_) => FriendProfileScreen(uid: uid)));

void openBook(BuildContext context, BookRef book) => Navigator.of(
  context,
).push(MaterialPageRoute(builder: (_) => BookPageScreen(book: book)));

void openPost(BuildContext context, Post post, {bool compose = false}) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PostDetailScreen(postId: post.id, initial: post, compose: compose),
      ),
    );

class StarRating extends StatelessWidget {
  const StarRating({required this.rating, this.size = 16, super.key});

  /// 0..5; halves are rounded to the nearest half star.
  final double rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    final halves = (rating * 2).round();
    return Semantics(
      label: '${rating.toStringAsFixed(1)} out of 5 stars',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++)
            Icon(
              halves >= i * 2
                  ? Icons.star_rounded
                  : halves == i * 2 - 1
                  ? Icons.star_half_rounded
                  : Icons.star_outline_rounded,
              size: size,
              color: starColor,
            ),
        ],
      ),
    );
  }
}

/// A book cover from a remote [BookRef.coverUrl], a local file, or the
/// generated colour block.
class BookThumb extends StatelessWidget {
  const BookThumb({
    required this.book,
    this.coverPath,
    this.width = 48,
    this.height = 72,
    super.key,
  });

  final BookRef book;
  final String? coverPath;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fallback = BookCover(
      title: book.title,
      coverPath: coverPath,
      width: width,
      height: height,
      shadow: false,
    );
    final url = book.coverUrl;
    if (url.isEmpty || !url.startsWith('https://')) {
      return DefaultTextStyle.merge(
        style: TextStyle(fontSize: width < 60 ? 8 : 12),
        child: fallback,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: BookCover.colorFor(book.title),
        borderRadius: BrutalTokens.smallBorderRadius,
        border: Border.all(color: scheme.outline, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.network(
        url,
        fit: BoxFit.cover,
        width: width,
        height: height,
        semanticLabel: book.title,
        errorBuilder: (_, _, _) => DefaultTextStyle.merge(
          style: TextStyle(fontSize: width < 60 ? 8 : 12),
          child: BookCover(
            title: book.title,
            coverPath: null,
            width: width,
            height: height,
            shadow: false,
          ),
        ),
      ),
    );
  }
}

/// Wording for a post's headline: "Ayesha finished reading Dracula".
String postVerb(Post post) => switch (post.type) {
  PostType.started => 'started reading',
  PostType.finished => 'finished reading',
  PostType.shelved => 'wants to read',
  PostType.progress => 'is ${post.progress}% through',
  PostType.review => 'reviewed',
  PostType.rating => 'rated',
  PostType.quote => 'shared a quote from',
  PostType.badge => 'earned the ${post.badgeTitle} badge',
};

(IconData, Color) postIcon(PostType type) => switch (type) {
  PostType.started => (Icons.menu_book_outlined, BrutalColors.blue),
  PostType.finished => (Icons.check_circle_outline, BrutalColors.green),
  PostType.shelved => (Icons.bookmark_add_outlined, BrutalColors.pink),
  PostType.progress => (Icons.trending_up, BrutalColors.blue),
  PostType.review => (Icons.rate_review_outlined, BrutalColors.yellow),
  PostType.rating => (Icons.star_outline, BrutalColors.yellow),
  PostType.quote => (Icons.format_quote, BrutalColors.pink),
  PostType.badge => (Icons.emoji_events_outlined, BrutalColors.yellow),
};

/// A post in a feed: author, what happened, the book, reactions and the
/// comment count. Follows the live document, so counts stay current and a
/// deleted post disappears.
class PostCard extends ConsumerStatefulWidget {
  const PostCard({required this.post, this.expanded = false, super.key});

  /// The post as loaded with the page (shown until the live copy arrives).
  final Post post;

  /// Full text and no tap-to-open (on the post's own page).
  final bool expanded;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  /// Reaction shown while a change is being saved.
  ReactionType? _pending;
  bool _saving = false;

  Future<void> _react(ReactionType? current, ReactionType? next) async {
    final repository = ref.read(communityRepositoryProvider);
    final me = ref.read(myProfileProvider).valueOrNull;
    if (repository == null || me == null) {
      _snack('Choose a username to react to posts.');
      return;
    }
    setState(() {
      _pending = next;
      _saving = true;
    });
    try {
      await repository.setReaction(widget.post.id, next, me);
    } catch (error) {
      _snack(socialErrorMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pickReaction(ReactionType? current) async {
    final choice = await showReactionPicker(context, current: current);
    if (choice == null || !mounted) return;
    await _react(current, choice.type);
  }

  Future<void> _delete(Post post) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this post?'),
        content: const Text(
          'Its reactions and comments are deleted too. This can’t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: BrutalColors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(communityRepositoryProvider)!.deletePost(post.id);
      _snack('Post deleted.');
    } catch (error) {
      _snack(socialErrorMessage(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(postProvider(widget.post.id));
    // Once the live document is known to be gone, hide the card.
    if (live.hasValue && live.value == null) return const SizedBox.shrink();
    final stored = live.valueOrNull ?? widget.post;
    final mine = ref.watch(myReactionProvider(widget.post.id)).valueOrNull;
    final reaction = _saving ? _pending : mine;
    final post = _saving ? stored.withReaction(mine, _pending) : stored;
    final myUid = ref.watch(communityRepositoryProvider)?.uid;
    final theme = Theme.of(context);

    return BrutalCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 4),
      onTap: widget.expanded ? null : () => openPost(context, post),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PostHeader(
            post: post,
            onDelete: post.authorUid == myUid ? () => _delete(post) : null,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PostBody(post: post, expanded: widget.expanded),
          ),
          if (post.reactionTotal > 0 || post.commentCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10, right: 8),
              child: Row(
                children: [
                  if (post.reactionTotal > 0)
                    Flexible(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => showReactionsSheet(context, post.id),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            '${post.topReactions.take(3).map((r) => r.emoji).join()} '
                            '${post.reactionTotal}',
                            style: theme.textTheme.labelMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (post.commentCount > 0)
                    Text(
                      '${post.commentCount} '
                      '${post.commentCount == 1 ? 'comment' : 'comments'}',
                      style: theme.textTheme.labelMedium,
                    ),
                ],
              ),
            ),
          const Divider(height: 12),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => _react(
                    reaction,
                    reaction == null ? ReactionType.like : null,
                  ),
                  onLongPress: () => _pickReaction(reaction),
                  style: _actionStyle(theme, active: reaction != null),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      reaction == null
                          ? '👍 Like'
                          : '${reaction.emoji} ${reaction.label}',
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'More reactions',
                visualDensity: VisualDensity.compact,
                onPressed: () => _pickReaction(reaction),
                icon: const Icon(Icons.add_reaction_outlined, size: 20),
              ),
              Expanded(
                child: TextButton(
                  onPressed: () => openPost(context, post, compose: true),
                  style: _actionStyle(theme),
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mode_comment_outlined, size: 18),
                        SizedBox(width: 6),
                        Text('Comment'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  ButtonStyle _actionStyle(ThemeData theme, {bool active = false}) =>
      TextButton.styleFrom(
        foregroundColor: active
            ? BrutalColors.blue
            : theme.colorScheme.onSurfaceVariant,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
        visualDensity: VisualDensity.compact,
      );
}

class _PostHeader extends StatelessWidget {
  const _PostHeader({required this.post, this.onDelete});

  final Post post;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = postIcon(post.type);
    final name = post.authorDisplayName.isEmpty
        ? '@${post.authorUsername}'
        : post.authorDisplayName;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          customBorder: const CircleBorder(),
          onTap: () => openProfile(context, post.authorUid),
          child: SizedBox.square(
            dimension: 42,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                UserAvatar(uid: post.authorUid, size: 38),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.colorScheme.surface,
                        width: 1.5,
                      ),
                    ),
                    child: Icon(icon, size: 11, color: BrutalColors.ink),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: ' ${postVerb(post)}'),
                      if (post.book != null)
                        TextSpan(
                          text: ' ${post.title}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                    ],
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '@${post.authorUsername} · ${timeAgo(post.createdAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      post.visibility == PostVisibility.public
                          ? Icons.public
                          : Icons.group_outlined,
                      size: 12,
                      semanticLabel: post.visibility.label,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (onDelete != null)
          PopupMenuButton<String>(
            tooltip: 'Post options',
            icon: const Icon(Icons.more_horiz, size: 20),
            onSelected: (_) => onDelete!(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'delete', child: Text('Delete post')),
            ],
          )
        else
          const SizedBox(width: 8),
      ],
    );
  }
}

/// What a post says: the quote, review, rating, progress or badge, then
/// the book it is about.
class PostBody extends StatelessWidget {
  const PostBody({required this.post, this.expanded = false, super.key});

  final Post post;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final children = <Widget>[];

    switch (post.type) {
      case PostType.quote:
        children.add(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BrutalTokens.smallBorderRadius,
              border: const Border(
                left: BorderSide(color: BrutalColors.yellow, width: 4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '“${post.quote}”',
                  maxLines: expanded ? null : 8,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontFamily: 'serif',
                    fontStyle: FontStyle.italic,
                  ),
                ),
                if (post.chapter.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(post.chapter, style: theme.textTheme.labelSmall),
                ],
              ],
            ),
          ),
        );
      case PostType.review || PostType.rating:
        children.add(StarRating(rating: post.rating.toDouble(), size: 18));
      case PostType.progress:
        children.add(
          Row(
            children: [
              Expanded(child: BrutalProgressBar(value: post.progress / 100)),
              const SizedBox(width: 8),
              Text('${post.progress}%', style: theme.textTheme.labelMedium),
            ],
          ),
        );
      case PostType.badge:
        final badge = Badges.byId(post.badgeId);
        children.add(
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: BrutalColors.yellow,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.outline, width: 1.5),
                ),
                child: Icon(
                  badge?.icon ?? Icons.emoji_events_outlined,
                  color: BrutalColors.ink,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(post.badgeTitle, style: theme.textTheme.titleSmall),
                    if (badge != null)
                      Text(badge.description, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        );
      case PostType.started || PostType.finished || PostType.shelved:
        break;
    }

    if (post.text.isNotEmpty) {
      children.add(
        Text(
          post.text,
          maxLines: expanded ? null : 6,
          overflow: expanded ? null : TextOverflow.ellipsis,
        ),
      );
    }

    final book = post.book;
    if (book != null) {
      children.add(
        InkWell(
          borderRadius: BrutalTokens.smallBorderRadius,
          onTap: () => openBook(context, book),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                BookThumb(book: book, width: 40, height: 60),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      if (book.author.isNotEmpty)
                        Text(
                          book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      );
    }

    if (children.isEmpty) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Result of [showReactionPicker]: a reaction, or `type == null` to remove.
class ReactionChoice {
  const ReactionChoice(this.type);

  final ReactionType? type;
}

Future<ReactionChoice?> showReactionPicker(
  BuildContext context, {
  ReactionType? current,
}) => showModalBottomSheet<ReactionChoice>(
  context: context,
  builder: (context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('React', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final type in ReactionType.values)
                  Semantics(
                    selected: type == current,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.pop(context, ReactionChoice(type)),
                      child: Container(
                        width: 56,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: type == current
                              ? Border.all(color: BrutalColors.blue, width: 2)
                              : null,
                        ),
                        child: Column(
                          children: [
                            Text(
                              type.emoji,
                              style: const TextStyle(fontSize: 26),
                            ),
                            const SizedBox(height: 2),
                            Text(type.label, style: theme.textTheme.labelSmall),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (current != null) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, const ReactionChoice(null)),
                child: const Text('Remove my reaction'),
              ),
            ],
          ],
        ),
      ),
    );
  },
);

/// Who reacted to a post.
Future<void> showReactionsSheet(BuildContext context, String postId) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (context, controller) => Consumer(
          builder: (context, ref, _) => ref
              .watch(reactionsListProvider(postId))
              .when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) =>
                    Center(child: Text(socialErrorMessage(error))),
                data: (items) => ListView(
                  controller: controller,
                  children: [
                    for (final reaction in items)
                      ListTile(
                        leading: UserAvatar(uid: reaction.uid, size: 36),
                        title: Text(
                          reaction.displayName.isEmpty
                              ? '@${reaction.username}'
                              : reaction.displayName,
                        ),
                        subtitle: Text('@${reaction.username}'),
                        trailing: Text(
                          reaction.type.emoji,
                          style: const TextStyle(fontSize: 22),
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          openProfile(context, reaction.uid);
                        },
                      ),
                  ],
                ),
              ),
        ),
      ),
    );

/// Paginated, pull-to-refresh list of posts.
class FeedList extends ConsumerStatefulWidget {
  const FeedList({
    required this.query,
    required this.empty,
    this.header,
    super.key,
  });

  final FeedQuery query;

  /// Shown when there are no posts.
  final Widget empty;
  final Widget? header;

  @override
  ConsumerState<FeedList> createState() => _FeedListState();
}

class _FeedListState extends ConsumerState<FeedList> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (_scroll.position.extentAfter < 600) {
      ref.read(feedProvider(widget.query).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(feedProvider(widget.query));
    final controller = ref.read(feedProvider(widget.query).notifier);
    final header = widget.header;
    final Widget body;
    if (!state.loaded && state.items.isEmpty) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ?header,
          const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      );
    } else if (state.items.isEmpty) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ?header,
          if (state.error != null)
            EmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Posts could not be loaded',
              message: socialErrorMessage(state.error!),
              action: TextButton(
                onPressed: controller.refresh,
                child: const Text('Try again'),
              ),
            )
          else
            widget.empty,
        ],
      );
    } else {
      final offset = header == null ? 0 : 1;
      body = ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: state.items.length + offset + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 14),
        itemBuilder: (context, index) {
          if (header != null && index == 0) return header;
          final i = index - offset;
          if (i < state.items.length) {
            return PostCard(
              key: ValueKey(state.items[i].id),
              post: state.items[i],
            );
          }
          return _FeedFooter(state: state, onMore: controller.loadMore);
        },
      );
    }
    return RefreshIndicator(onRefresh: controller.refresh, child: body);
  }
}

class _FeedFooter extends StatelessWidget {
  const _FeedFooter({required this.state, required this.onMore});

  final FeedState state;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    if (state.loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (state.error != null) {
      return Center(
        child: TextButton(
          onPressed: onMore,
          child: Text('${socialErrorMessage(state.error!)} Tap to retry.'),
        ),
      );
    }
    if (state.hasMore) {
      return Center(
        child: TextButton(onPressed: onMore, child: const Text('Load more')),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        'You’re all caught up.',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// A rating/review card with the reviewer and optionally the book.
class ReviewTile extends StatelessWidget {
  const ReviewTile({required this.review, this.book, super.key});

  final Review review;

  /// Shown instead of the reviewer (on a reader's profile).
  final BookRef? book;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = this.book;
    return BrutalCard(
      padding: const EdgeInsets.all(12),
      onTap: book == null
          ? () => openProfile(context, review.uid)
          : () => openBook(context, book),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (book != null)
            BookThumb(book: book, width: 40, height: 60)
          else
            UserAvatar(uid: review.uid, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book?.title ??
                      (review.displayName.isEmpty
                          ? '@${review.username}'
                          : review.displayName),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                StarRating(rating: review.rating.toDouble()),
                if (review.text.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    review.text,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (review.updatedAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (book == null) '@${review.username}',
                      formatDate(review.updatedAt!),
                    ].join(' · '),
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
