import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'community_models.dart';
import 'community_repository.dart';
import 'feed_pager.dart';
import 'social_models.dart';
import 'social_providers.dart';

final communityRepositoryProvider = Provider<CommunityRepository?>((ref) {
  final user = ref.watch(authUserProvider).valueOrNull;
  if (user == null) return null;
  return CommunityRepository(FirebaseFirestore.instance, user.uid);
});

/// Bumped after the user publishes or deletes something, so open feeds
/// reload and show it.
final communityRevisionProvider = StateProvider<int>((ref) => 0);

/// Uids of the user's friends (empty until loaded or when signed out).
final friendUidsProvider = Provider<Set<String>>((ref) {
  final friends = ref.watch(friendsProvider).valueOrNull ?? const <Friend>[];
  return {for (final friend in friends) friend.uid};
});

/// Live post document; null once deleted (or not readable).
final postProvider = StreamProvider.autoDispose.family<Post?, String>((
  ref,
  postId,
) {
  final repository = ref.watch(communityRepositoryProvider);
  return repository?.watchPost(postId) ?? Stream.value(null);
});

final myReactionProvider = StreamProvider.autoDispose
    .family<ReactionType?, String>((ref, postId) {
      final repository = ref.watch(communityRepositoryProvider);
      return repository?.watchMyReaction(postId) ?? Stream.value(null);
    });

final commentsProvider = StreamProvider.autoDispose
    .family<List<PostComment>, String>((ref, postId) {
      final repository = ref.watch(communityRepositoryProvider);
      return repository?.watchComments(postId) ?? Stream.value(const []);
    });

final reactionsListProvider = FutureProvider.autoDispose
    .family<List<Reaction>, String>((ref, postId) async {
      final repository = ref.watch(communityRepositoryProvider);
      return repository?.reactions(postId) ?? const [];
    });

final shelfProvider = StreamProvider.autoDispose
    .family<List<ShelfEntry>, String>((ref, uid) {
      final repository = ref.watch(communityRepositoryProvider);
      return repository?.watchShelf(uid) ?? Stream.value(const []);
    });

final badgeUnlocksOfProvider = StreamProvider.autoDispose
    .family<List<PublicBadge>, String>((ref, uid) {
      final repository = ref.watch(communityRepositoryProvider);
      return repository?.watchBadges(uid) ?? Stream.value(const []);
    });

final readerStatsProvider = FutureProvider.autoDispose
    .family<ReaderStats, String>((ref, uid) async {
      ref.watch(communityRevisionProvider);
      final repository = ref.watch(communityRepositoryProvider);
      return repository?.readerStats(uid) ?? ReaderStats.empty;
    });

final readerReviewsProvider = FutureProvider.autoDispose
    .family<List<ReaderReview>, String>((ref, uid) async {
      ref.watch(communityRevisionProvider);
      final repository = ref.watch(communityRepositoryProvider);
      return repository?.reviewsBy(uid) ?? const [];
    });

final bookRatingProvider = FutureProvider.autoDispose
    .family<RatingSummary, String>((ref, bookKey) async {
      ref.watch(communityRevisionProvider);
      final repository = ref.watch(communityRepositoryProvider);
      return repository?.ratingOf(bookKey) ?? RatingSummary.empty;
    });

// --------------------------------------------------------------- feeds

enum FeedKind { everyone, friends, author, bookQuotes }

/// Which posts a feed shows. Used as a provider family key.
class FeedQuery {
  const FeedQuery._(this.kind, {this.id = '', this.type});

  static const everyone = FeedQuery._(FeedKind.everyone);
  static const friends = FeedQuery._(FeedKind.friends);

  /// Posts by one reader, optionally of one [type] (e.g. quotes).
  const FeedQuery.author(String uid, {PostType? type})
    : this._(FeedKind.author, id: uid, type: type);

  const FeedQuery.bookQuotes(String bookKey)
    : this._(FeedKind.bookQuotes, id: bookKey);

  final FeedKind kind;
  final String id;
  final PostType? type;

  @override
  bool operator ==(Object other) =>
      other is FeedQuery &&
      other.kind == kind &&
      other.id == id &&
      other.type == type;

  @override
  int get hashCode => Object.hash(kind, id, type);
}

class FeedState {
  const FeedState({
    this.items = const [],
    this.loading = false,
    this.hasMore = true,
    this.error,
    this.loaded = false,
  });

  final List<Post> items;
  final bool loading;
  final bool hasMore;
  final Object? error;

  /// The first page has arrived (or failed).
  final bool loaded;

  FeedState copyWith({
    List<Post>? items,
    bool? loading,
    bool? hasMore,
    Object? error,
    bool clearError = false,
    bool? loaded,
  }) => FeedState(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    hasMore: hasMore ?? this.hasMore,
    error: clearError ? null : error ?? this.error,
    loaded: loaded ?? this.loaded,
  );
}

/// A paginated, pull-to-refresh feed of posts.
class FeedController extends StateNotifier<FeedState> {
  FeedController(this._open, {this.pageSize = CommunityRepository.pageSize})
    : super(const FeedState()) {
    refresh();
  }

  /// Builds a fresh pager; null when signed out.
  final Future<MergedPager<Post>?> Function() _open;
  final int pageSize;
  MergedPager<Post>? _pager;
  int _generation = 0;

  Future<void> refresh() async {
    final generation = ++_generation;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final pager = await _open();
      if (!mounted || generation != _generation) return;
      _pager = pager;
      final items = pager == null ? <Post>[] : await pager.next(pageSize);
      if (!mounted || generation != _generation) return;
      state = FeedState(
        items: items,
        hasMore: pager?.hasMore ?? false,
        loaded: true,
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      state = state.copyWith(loading: false, error: error, loaded: true);
    }
  }

  Future<void> loadMore() async {
    final pager = _pager;
    if (pager == null || state.loading || !state.hasMore) return;
    final generation = _generation;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final items = await pager.next(pageSize);
      if (!mounted || generation != _generation) return;
      final seen = {for (final post in state.items) post.id};
      state = state.copyWith(
        items: [
          ...state.items,
          ...items.where((post) => !seen.contains(post.id)),
        ],
        loading: false,
        hasMore: pager.hasMore,
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      state = state.copyWith(loading: false, error: error);
    }
  }

  /// Drops a deleted post without reloading.
  void remove(String postId) {
    state = state.copyWith(
      items: [
        for (final post in state.items)
          if (post.id != postId) post,
      ],
    );
  }
}

final feedProvider = StateNotifierProvider.autoDispose
    .family<FeedController, FeedState, FeedQuery>((ref, query) {
      ref.watch(communityRevisionProvider);
      final repository = ref.watch(communityRepositoryProvider);
      if (query.kind == FeedKind.friends || query.kind == FeedKind.author) {
        // Rebuild when the friend list changes: it decides what is visible.
        ref.watch(friendUidsProvider);
      }
      Future<MergedPager<Post>?> open() async {
        if (repository == null) return null;
        switch (query.kind) {
          case FeedKind.everyone:
            return repository.everyone();
          case FeedKind.friends:
            final friends = await ref.read(friendsProvider.future);
            return repository.friends([for (final f in friends) f.uid]);
          case FeedKind.author:
            final friends = await ref.read(friendsProvider.future);
            final visible =
                query.id == repository.uid ||
                friends.any((friend) => friend.uid == query.id);
            return repository.postsBy(
              query.id,
              includeFriendsOnly: visible,
              type: query.type,
            );
          case FeedKind.bookQuotes:
            return repository.quotesFrom(query.id);
        }
      }

      return FeedController(open);
    });
