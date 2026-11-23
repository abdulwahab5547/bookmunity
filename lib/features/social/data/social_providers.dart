import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/db/app_database.dart';
import '../../achievements/data/achievement_service.dart';
import '../../achievements/domain/badges.dart';
import 'community_models.dart';
import 'community_providers.dart';
import 'community_repository.dart';
import 'social_models.dart';
import 'social_repository.dart';

/// False on platforms where Firebase is not configured (e.g. Linux).
final firebaseReadyProvider = Provider<bool>((ref) => Firebase.apps.isNotEmpty);

final authUserProvider = StreamProvider<User?>((ref) {
  if (!ref.watch(firebaseReadyProvider)) return Stream.value(null);
  return FirebaseAuth.instance.authStateChanges();
});

final socialRepositoryProvider = Provider<SocialRepository?>((ref) {
  final user = ref.watch(authUserProvider).valueOrNull;
  if (user == null) return null;
  return SocialRepository(FirebaseFirestore.instance, user.uid);
});

final myProfileProvider = StreamProvider<Profile?>((ref) {
  final repository = ref.watch(socialRepositoryProvider);
  return repository?.watchMyProfile() ?? Stream.value(null);
});

/// Startup gate state: does the signed-in user have a profile yet?
final myProfileStatusProvider = StreamProvider<ProfileStatus>((ref) {
  final repository = ref.watch(socialRepositoryProvider);
  if (repository == null) return Stream.value(ProfileStatus.unavailable);
  return repository.watchMyProfileStatus();
});

/// Set by signup while it creates the profile, so the gate shows a spinner
/// instead of flashing the username screen.
final signupInProgressProvider = StateProvider<bool>((ref) => false);

/// Uploaded photo for a user (null when they use the cute avatar).
final profilePhotoProvider = StreamProvider.autoDispose
    .family<Uint8List?, String>((ref, uid) {
      final repository = ref.watch(socialRepositoryProvider);
      return repository?.watchPhoto(uid) ?? Stream.value(null);
    });

final friendsProvider = StreamProvider<List<Friend>>((ref) {
  final repository = ref.watch(socialRepositoryProvider);
  return repository?.watchFriends() ?? Stream.value(const []);
});

final incomingRequestsProvider = StreamProvider<List<FriendRequest>>((ref) {
  final repository = ref.watch(socialRepositoryProvider);
  return repository?.watchIncomingRequests() ?? Stream.value(const []);
});

final outgoingRequestsProvider = StreamProvider<List<FriendRequest>>((ref) {
  final repository = ref.watch(socialRepositoryProvider);
  return repository?.watchOutgoingRequests() ?? Stream.value(const []);
});

final profileProvider = StreamProvider.autoDispose.family<Profile?, String>((
  ref,
  uid,
) {
  final repository = ref.watch(socialRepositoryProvider);
  return repository?.watchProfile(uid) ?? Stream.value(null);
});

final reviewsProvider = StreamProvider.autoDispose.family<List<Review>, String>(
  (ref, bookKey) {
    final repository = ref.watch(socialRepositoryProvider);
    return repository?.watchReviews(bookKey) ?? Stream.value(const []);
  },
);

/// Whether reading activity is shared with friends (on by default).
final shareActivityProvider =
    StateNotifierProvider<ShareActivityNotifier, bool>(
      (ref) => ShareActivityNotifier()..load(),
    );

class ShareActivityNotifier extends StateNotifier<bool> {
  ShareActivityNotifier() : super(true);

  static const _key = 'share_activity';

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    if (mounted) state = preferences.getBool(_key) ?? true;
  }

  Future<void> set(bool value) async {
    state = value;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_key, value);
  }
}

/// Human-readable message for Firestore failures shown in the UI.
String socialErrorMessage(Object error) {
  if (error is FirebaseException) {
    return switch (error.code) {
      'permission-denied' => 'You do not have access to this.',
      'unavailable' => 'You appear to be offline.',
      'not-found' || 'failed-precondition' =>
        'Social features are not set up for this app yet.',
      _ => error.message ?? 'Something went wrong (${error.code}).',
    };
  }
  if (error is UsernameTakenException) return error.toString();
  return 'Something went wrong: $error';
}

// ------------------------------------------------------------------ hooks
//
// Best-effort: social posting must never break reading, so failures are
// logged and swallowed. Reading updates become Community posts (see
// docs/cloud-data.md); the legacy `users/{uid}/activity` feed is no longer
// written.

/// Activity helpers usable from widgets via `ref.read(socialActivityProvider)`.
final socialActivityProvider = Provider<SocialActivity>(SocialActivity.new);

class SocialActivity {
  SocialActivity(this._ref);

  final Ref _ref;

  /// Runs [action] when signed in with a profile. Automatic updates honour
  /// the "share activity" setting ([shared]); things the user explicitly
  /// chose to post do not.
  Future<bool> _publish(
    Future<void> Function(CommunityRepository repository, Profile me) action, {
    bool shared = true,
    bool rethrowErrors = false,
  }) async {
    try {
      final repository = _ref.read(communityRepositoryProvider);
      if (repository == null) return false;
      if (shared && !_ref.read(shareActivityProvider)) return false;
      final profile = await _ref.read(myProfileProvider.future);
      if (profile == null) return false;
      await action(repository, profile);
      _ref.read(communityRevisionProvider.notifier).state++;
      return true;
    } catch (error) {
      if (rethrowErrors) rethrow;
      debugPrint('Community post not published: $error');
      return false;
    }
  }

  static BookRef bookRef(Book book) =>
      BookRef(bookKey: book.bookKey, title: book.title, author: book.author);

  Future<void> _update(Book book, PostType type, {int progress = 0}) {
    if (book.bookKey.isEmpty) return Future.value();
    return _publish(
      (repository, me) => repository.createPostOnce(
        PostIds.update(me.uid, type, book.bookKey),
        PostDraft(type: type, book: bookRef(book), progress: progress),
        me,
      ),
    );
  }

  Future<void> bookStarted(Book book) => _update(book, PostType.started);

  Future<void> bookShelved(Book book) => _update(book, PostType.shelved);

  /// Halfway milestone, posted once per book.
  Future<void> bookHalfway(Book book) =>
      _update(book, PostType.progress, progress: 50);

  Future<void> bookFinished(Book book) async {
    await _update(book, PostType.finished);
    await syncProfileStats();
  }

  Future<void> badgesEarned(List<BadgeDefinition> badges) async {
    // Avoid flooding the feed when many badges unlock at once.
    for (final badge in badges.take(3)) {
      await _publish(
        (repository, me) => repository.createPostOnce(
          PostIds.badge(me.uid, badge.id),
          PostDraft(
            type: PostType.badge,
            badgeId: badge.id,
            badgeTitle: badge.title,
          ),
          me,
        ),
      );
    }
    await syncProfileStats();
  }

  /// After saving a review: creates or updates the review post (a "rating"
  /// post when there is no text). With sharing off an existing post is
  /// still kept in sync, but no new one is created.
  Future<void> reviewSaved(Book book, int rating, String text) async {
    final sharing = _ref.read(shareActivityProvider);
    await _publish(
      (repository, me) => repository.upsertPost(
        PostIds.review(me.uid, book.bookKey),
        PostDraft(
          type: text.trim().isEmpty ? PostType.rating : PostType.review,
          book: bookRef(book),
          rating: rating,
          text: text,
        ),
        me,
        create: sharing,
      ),
      shared: false,
    );
  }

  /// After deleting a review: removes its post.
  Future<void> reviewDeleted(Book book) => _publish(
    (repository, me) =>
        repository.deletePostIfExists(PostIds.review(me.uid, book.bookKey)),
    shared: false,
  );

  /// Shares a highlighted passage. Explicit, so it ignores the sharing
  /// setting, and errors reach the caller.
  Future<bool> shareQuote({
    required Book book,
    required String quote,
    required String note,
    required String chapter,
    required PostVisibility visibility,
  }) => _publish(
    (repository, me) => repository.createPost(
      PostDraft(
        type: PostType.quote,
        visibility: visibility,
        book: bookRef(book),
        quote: quote,
        text: note,
        chapter: chapter,
      ),
      me,
    ),
    shared: false,
    rethrowErrors: true,
  );

  Future<ProfileStats> currentStats() async {
    final service = await _ref.read(achievementServiceProvider.future);
    final summary = await service.summary();
    final unlocks = await _ref.read(badgeUnlocksProvider.future);
    return ProfileStats(
      booksFinished: summary.finishedBooks,
      currentStreak: summary.currentStreak,
      longestStreak: summary.longestStreak,
      badgeCount: unlocks.length,
    );
  }

  /// Publishes current counts to the public profile when they changed.
  Future<void> syncProfileStats() async {
    try {
      final repository = _ref.read(socialRepositoryProvider);
      if (repository == null) return;
      final profile = await _ref.read(myProfileProvider.future);
      if (profile == null) return;
      final stats = await currentStats();
      if (stats.booksFinished == profile.booksFinished &&
          stats.currentStreak == profile.currentStreak &&
          stats.longestStreak == profile.longestStreak &&
          stats.badgeCount == profile.badgeCount) {
        return;
      }
      await repository.updateProfile(stats: stats);
    } catch (error) {
      debugPrint('Profile stats not synced: $error');
    }
  }
}

/// Installed in main.dart so badge unlocks reach friends.
List<BadgeUnlockListener> socialBadgeListeners(Ref ref) => [
  (badges) => ref.read(socialActivityProvider).badgesEarned(badges),
];
