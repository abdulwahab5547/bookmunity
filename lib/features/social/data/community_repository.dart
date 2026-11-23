import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_models.dart';
import 'feed_pager.dart';
import 'social_models.dart';

/// Reads and writes for the Community tab, reader profiles and book pages.
///
/// Every write mirrors the "Community" block in firestore.rules. Counters on
/// a post (`reactions`, `commentCount`) only ever change in the same atomic
/// write as the reaction or comment they count, using
/// `FieldValue.increment`, and the rules check both sides of that pairing.
class CommunityRepository {
  CommunityRepository(this._db, this.uid);

  final FirebaseFirestore _db;

  /// The signed-in user.
  final String uid;

  static const pageSize = 15;

  CollectionReference<Map<String, dynamic>> get _posts =>
      _db.collection('posts');
  CollectionReference<Map<String, dynamic>> _reactionsOf(String postId) =>
      _posts.doc(postId).collection('reactions');
  CollectionReference<Map<String, dynamic>> _commentsOf(String postId) =>
      _posts.doc(postId).collection('comments');
  CollectionReference<Map<String, dynamic>> _user(String owner, String name) =>
      _db.collection('users').doc(owner).collection(name);
  CollectionReference<Map<String, dynamic>> _reviewsOf(String bookKey) =>
      _db.collection('books').doc(reviewDocKey(bookKey)).collection('reviews');

  // -------------------------------------------------------------- feeds

  Query<Map<String, dynamic>> get _newestFirst =>
      _posts.orderBy('createdAt', descending: true);

  /// Public posts from every reader.
  MergedPager<Post> everyone() => _pager([
    _newestFirst.where('visibility', isEqualTo: PostVisibility.public.name),
  ]);

  /// Posts (public and friends-only) by the user and their friends. One
  /// query per 30 authors (`whereIn` limit), merged newest first. The rules
  /// allow this because every author in the query is a friend or the user.
  MergedPager<Post> friends(Iterable<String> friendUids) {
    final authors = {uid, ...friendUids}.toList();
    return _pager([
      for (final chunk in chunked(authors, CommunityLimits.whereInChunk))
        _newestFirst.where('authorUid', whereIn: chunk),
    ]);
  }

  /// A reader's posts. Friends-only posts are included only when the
  /// caller may read them ([includeFriendsOnly]: it is the user or a
  /// friend); otherwise the query must ask for public posts only, or the
  /// rules reject it.
  MergedPager<Post> postsBy(
    String author, {
    required bool includeFriendsOnly,
    PostType? type,
  }) {
    Query<Map<String, dynamic>> query = _newestFirst.where(
      'authorUid',
      isEqualTo: author,
    );
    if (type != null) query = query.where('type', isEqualTo: type.name);
    if (!includeFriendsOnly) {
      query = query.where('visibility', isEqualTo: PostVisibility.public.name);
    }
    return _pager([query]);
  }

  /// Public quotes from one book.
  MergedPager<Post> quotesFrom(String bookKey) => _pager([
    _newestFirst
        .where('bookKey', isEqualTo: reviewDocKey(bookKey))
        .where('type', isEqualTo: PostType.quote.name)
        .where('visibility', isEqualTo: PostVisibility.public.name),
  ]);

  MergedPager<Post> _pager(List<Query<Map<String, dynamic>>> queries) =>
      MergedPager<Post>([
        for (final query in queries) _QuerySource(query),
      ], timeOf: (post) => post.createdAt);

  Stream<Post?> watchPost(String postId) =>
      _posts.doc(postId).snapshots().map(Post.fromDoc);

  // -------------------------------------------------------------- posts

  /// Creates a post with a fresh id (quotes).
  Future<String> createPost(PostDraft draft, Profile me) async {
    final id = PostIds.random(uid, _posts.doc().id);
    await _posts.doc(id).set(draft.toCreateMap(me));
    return id;
  }

  /// Creates [postId] unless it already exists (one "finished" post per
  /// book, one post per badge, ...). Returns whether it was created.
  Future<bool> createPostOnce(String postId, PostDraft draft, Profile me) async {
    final ref = _posts.doc(postId);
    if ((await ref.get()).exists) return false;
    await ref.set(draft.toCreateMap(me));
    return true;
  }

  /// Updates [postId] if it exists; otherwise creates it when [create].
  Future<void> upsertPost(
    String postId,
    PostDraft draft,
    Profile me, {
    bool create = true,
  }) async {
    final ref = _posts.doc(postId);
    if ((await ref.get()).exists) {
      await ref.update(draft.toUpdateMap(me));
    } else if (create) {
      await ref.set(draft.toCreateMap(me));
    }
  }

  /// Deletes the user's post, then its comments and reactions. The rules
  /// let anyone delete reactions and comments of a post that no longer
  /// exists, so a partly finished clean-up can be completed later.
  Future<void> deletePost(String postId) async {
    final ref = _posts.doc(postId);
    final snapshot = await ref.get();
    if (!snapshot.exists) return;
    if (snapshot.data()?['authorUid'] != uid) {
      throw StateError('Only the author can delete a post.');
    }
    // List the children while the post (and so read access) still exists.
    final children = [
      ...(await _commentsOf(postId).get()).docs.map((d) => d.reference),
      ...(await _reactionsOf(postId).get()).docs.map((d) => d.reference),
    ];
    await ref.delete();
    for (final chunk in chunked(children, 400)) {
      final batch = _db.batch();
      for (final child in chunk) {
        batch.delete(child);
      }
      await batch.commit();
    }
  }

  Future<void> deletePostIfExists(String postId) async {
    try {
      await deletePost(postId);
    } on FirebaseException catch (error) {
      if (error.code != 'not-found') rethrow;
    }
  }

  // ---------------------------------------------------------- reactions

  Stream<ReactionType?> watchMyReaction(String postId) => _reactionsOf(
    postId,
  ).doc(uid).snapshots().map((doc) => Reaction.fromDoc(doc)?.type);

  Future<List<Reaction>> reactions(String postId) async {
    final result = await _reactionsOf(postId).limit(200).get();
    return [for (final doc in result.docs) ?Reaction.fromDoc(doc)];
  }

  /// Sets the user's reaction to [type], or removes it when null. Runs in a
  /// transaction so the counter change always matches the reaction that
  /// was really there before.
  Future<void> setReaction(String postId, ReactionType? type, Profile me) =>
      _db.runTransaction((transaction) async {
        final reactionRef = _reactionsOf(postId).doc(uid);
        final current = Reaction.fromDoc(await transaction.get(reactionRef));
        final before = current?.type;
        if (before == type) return;
        final postRef = _posts.doc(postId);
        transaction.update(postRef, {
          if (before != null) 'reactions.${before.name}': FieldValue.increment(-1),
          if (type != null) 'reactions.${type.name}': FieldValue.increment(1),
        });
        if (type == null) {
          transaction.delete(reactionRef);
        } else {
          transaction.set(reactionRef, {
            'uid': uid,
            'type': type.name,
            'username': me.username,
            'displayName': me.displayName,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });

  // ----------------------------------------------------------- comments

  Stream<List<PostComment>> watchComments(String postId) => _commentsOf(postId)
      .orderBy('createdAt')
      .limit(300)
      .snapshots()
      .map((snapshot) => snapshot.docs.map(PostComment.fromDoc).toList());

  /// Adds a comment, or a reply when [parentId] names a top-level comment.
  Future<void> addComment(
    String postId,
    String text,
    Profile me, {
    String parentId = '',
  }) {
    final body = text.trim();
    if (body.isEmpty) throw ArgumentError('Write something first.');
    final ref = _commentsOf(postId).doc();
    final batch = _db.batch()
      ..set(ref, {
        'authorUid': uid,
        'authorUsername': me.username,
        'authorDisplayName': me.displayName,
        'text': body.length > CommunityLimits.comment
            ? body.substring(0, CommunityLimits.comment)
            : body,
        'parentId': parentId,
        'createdAt': FieldValue.serverTimestamp(),
      })
      ..update(_posts.doc(postId), {
        'commentCount': FieldValue.increment(1),
        'commentOpId': ref.id,
      });
    return batch.commit();
  }

  /// Deletes a comment (and, for a top-level comment, its [replies] first).
  /// Allowed for the comment's author and the post's author; a comment's
  /// author may also remove replies to it.
  Future<void> deleteComment(
    String postId,
    PostComment comment, {
    List<PostComment> replies = const [],
  }) async {
    for (final reply in replies) {
      await _deleteOne(postId, reply.id);
    }
    await _deleteOne(postId, comment.id);
  }

  Future<void> _deleteOne(String postId, String commentId) {
    final batch = _db.batch()
      ..delete(_commentsOf(postId).doc(commentId))
      ..update(_posts.doc(postId), {
        'commentCount': FieldValue.increment(-1),
        'commentOpId': commentId,
      });
    return batch.commit();
  }

  // ----------------------------------------------------------- profiles

  /// Public bookshelf, written by the sync feature. Empty when missing.
  Stream<List<ShelfEntry>> watchShelf(String owner) => _user(owner, 'library')
      .limit(500)
      .snapshots()
      .map((snapshot) => snapshot.docs.map(ShelfEntry.fromDoc).toList());

  Stream<List<PublicBadge>> watchBadges(String owner) =>
      _user(owner, 'badges').snapshots().map(
        (snapshot) =>
            snapshot.docs.map(PublicBadge.fromDoc).toList()..sort(
              (a, b) => (b.unlockedAt ?? DateTime(0)).compareTo(
                a.unlockedAt ?? DateTime(0),
              ),
            ),
      );

  Query<Map<String, dynamic>> _reviewsBy(String owner) =>
      _db.collectionGroup('reviews').where('uid', isEqualTo: owner);

  /// The reader's ratings and reviews across all books, newest first.
  Future<List<ReaderReview>> reviewsBy(String owner, {int limit = 50}) async {
    final result = await _reviewsBy(
      owner,
    ).orderBy('updatedAt', descending: true).limit(limit).get();
    return result.docs.map(ReaderReview.fromDoc).toList();
  }

  /// Friend count and rating numbers, from aggregate queries so they
  /// cannot be inflated by the reader.
  Future<ReaderStats> readerStats(String owner) async {
    final results = await Future.wait([
      _user(owner, 'friends').count().get(),
      _reviewsBy(owner).aggregate(count(), average('rating')).get(),
    ]);
    final friends = results[0];
    final ratings = results[1];
    return ReaderStats(
      friends: friends.count ?? 0,
      ratings: ratings.count ?? 0,
      averageRating: ratings.getAverage('rating') ?? 0,
    );
  }

  // -------------------------------------------------------------- books

  Future<RatingSummary> ratingOf(String bookKey) async {
    final result = await _reviewsOf(
      bookKey,
    ).aggregate(count(), average('rating')).get();
    return RatingSummary(
      count: result.count ?? 0,
      average: result.getAverage('rating') ?? 0,
    );
  }
}

/// One Firestore query read page by page with a cursor.
class _QuerySource implements PagedSource<Post> {
  _QuerySource(this._query);

  final Query<Map<String, dynamic>> _query;
  DocumentSnapshot<Map<String, dynamic>>? _last;

  @override
  Future<SourcePage<Post>> fetch(int count) async {
    var query = _query.limit(count);
    final last = _last;
    if (last != null) query = query.startAfterDocument(last);
    final result = await query.get();
    if (result.docs.isNotEmpty) _last = result.docs.last;
    return SourcePage(
      [for (final doc in result.docs) ?Post.fromDoc(doc)],
      exhausted: result.docs.length < count,
    );
  }
}
