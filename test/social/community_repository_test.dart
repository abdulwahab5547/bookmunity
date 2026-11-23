import 'package:bookmunity/features/social/data/community_models.dart';
import 'package:bookmunity/features/social/data/community_repository.dart';
import 'package:bookmunity/features/social/data/social_models.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

Profile profile(String uid) => Profile(
  uid: uid,
  username: 'user_$uid',
  displayName: 'User $uid',
  booksFinished: 0,
  currentStreak: 0,
  longestStreak: 0,
  badgeCount: 0,
);

const book = BookRef(bookKey: 'emma|jane-austen', title: 'Emma', author: 'A');

/// A post document as the app writes it, with an explicit time.
Map<String, Object> postDoc(
  String author,
  int minute, {
  String visibility = 'public',
  String type = 'finished',
}) => {
  ...PostDraft(
    type: PostType.parse(type)!,
    book: book,
    visibility: PostVisibility.parse(visibility),
  ).toCreateMap(profile(author)),
  'createdAt': Timestamp.fromDate(DateTime(2026, 1, 1, 0, minute)),
  'updatedAt': Timestamp.fromDate(DateTime(2026, 1, 1, 0, minute)),
};

Future<Post> load(FakeFirebaseFirestore db, String id) async =>
    Post.fromDoc(await db.collection('posts').doc(id).get())!;

void main() {
  late FakeFirebaseFirestore db;
  late CommunityRepository repo;

  setUp(() {
    db = FakeFirebaseFirestore();
    repo = CommunityRepository(db, 'me');
  });

  test('createPostOnce does not duplicate deterministic posts', () async {
    final id = PostIds.update('me', PostType.finished, book.bookKey);
    const draft = PostDraft(type: PostType.finished, book: book);
    expect(await repo.createPostOnce(id, draft, profile('me')), isTrue);
    expect(await repo.createPostOnce(id, draft, profile('me')), isFalse);
    final post = await load(db, id);
    expect(post.authorUid, 'me');
    expect(post.commentCount, 0);
  });

  test('upsertPost updates content but keeps counters', () async {
    final id = PostIds.review('me', book.bookKey);
    await repo.upsertPost(
      id,
      const PostDraft(type: PostType.rating, book: book, rating: 3),
      profile('me'),
    );
    await repo.setReaction(id, ReactionType.love, profile('me'));
    await repo.upsertPost(
      id,
      const PostDraft(
        type: PostType.review,
        book: book,
        rating: 5,
        text: 'Loved it',
      ),
      profile('me'),
    );
    final post = await load(db, id);
    expect(post.type, PostType.review);
    expect(post.rating, 5);
    expect(post.text, 'Loved it');
    expect(post.reactions, {ReactionType.love: 1});

    // With sharing off, a missing post is not created.
    await repo.upsertPost(
      'me_review_other',
      const PostDraft(type: PostType.rating, book: book, rating: 2),
      profile('me'),
      create: false,
    );
    expect(
      (await db.collection('posts').doc('me_review_other').get()).exists,
      isFalse,
    );
  });

  test('reactions: one per reader, changeable and removable', () async {
    final id = await repo.createPost(
      const PostDraft(type: PostType.quote, book: book, quote: 'Q'),
      profile('me'),
    );
    final other = CommunityRepository(db, 'friend');

    await other.setReaction(id, ReactionType.like, profile('friend'));
    await repo.setReaction(id, ReactionType.like, profile('me'));
    expect((await load(db, id)).reactions, {ReactionType.like: 2});

    await repo.setReaction(id, ReactionType.haha, profile('me'));
    expect((await load(db, id)).reactions, {
      ReactionType.like: 1,
      ReactionType.haha: 1,
    });

    // Same reaction again is a no-op.
    await repo.setReaction(id, ReactionType.haha, profile('me'));
    expect((await load(db, id)).reactionTotal, 2);

    await repo.setReaction(id, null, profile('me'));
    expect((await load(db, id)).reactions, {ReactionType.like: 1});
    expect(await repo.watchMyReaction(id).first, isNull);
    expect(await other.watchMyReaction(id).first, ReactionType.like);

    final who = await repo.reactions(id);
    expect(who.single.uid, 'friend');
    expect(who.single.displayName, 'User friend');
  });

  test('comments, replies and deletes keep commentCount right', () async {
    final id = await repo.createPost(
      const PostDraft(type: PostType.quote, book: book, quote: 'Q'),
      profile('me'),
    );
    final friend = CommunityRepository(db, 'friend');
    await friend.addComment(id, 'Nice', profile('friend'));
    final top = (await repo.watchComments(id).first).single;
    await repo.addComment(id, ' Thanks! ', profile('me'), parentId: top.id);
    await friend.addComment(id, 'Another', profile('friend'));
    expect((await load(db, id)).commentCount, 3);

    final comments = await repo.watchComments(id).first;
    final threads = CommentThread.group(comments);
    expect(threads, hasLength(2));
    expect(threads.first.replies.single.text, 'Thanks!');
    expect(threads.first.replies.single.parentId, top.id);

    // Deleting a thread removes its replies too.
    await repo.deleteComment(
      id,
      threads.first.comment,
      replies: threads.first.replies,
    );
    expect((await load(db, id)).commentCount, 1);
    expect(await repo.watchComments(id).first, hasLength(1));
    expect(
      () => repo.addComment(id, '   ', profile('me')),
      throwsArgumentError,
    );
  });

  test('deletePost removes the post with its comments and reactions', () async {
    final id = await repo.createPost(
      const PostDraft(type: PostType.quote, book: book, quote: 'Q'),
      profile('me'),
    );
    await repo.addComment(id, 'note to self', profile('me'));
    await repo.setReaction(id, ReactionType.wow, profile('me'));
    await repo.deletePost(id);
    expect((await db.collection('posts').doc(id).get()).exists, isFalse);
    expect(
      (await db.collection('posts').doc(id).collection('comments').get()).docs,
      isEmpty,
    );
    expect(
      (await db.collection('posts').doc(id).collection('reactions').get()).docs,
      isEmpty,
    );

    // Someone else's post cannot be deleted through the repository.
    await db.collection('posts').doc('x_1').set(postDoc('x', 1));
    expect(() => repo.deletePost('x_1'), throwsStateError);
  });

  test('everyone() pages through public posts newest first', () async {
    for (var i = 0; i < 20; i++) {
      await db
          .collection('posts')
          .doc('a_$i')
          .set(postDoc('a', i, visibility: i.isEven ? 'public' : 'friends'));
    }
    final pager = repo.everyone();
    final first = await pager.next(4);
    final second = await pager.next(4);
    final rest = await pager.next(10);
    expect(first.map((p) => p.id), ['a_18', 'a_16', 'a_14', 'a_12']);
    expect(second.map((p) => p.id), ['a_10', 'a_8', 'a_6', 'a_4']);
    expect(rest.map((p) => p.id), ['a_2', 'a_0']);
    expect(pager.hasMore, isFalse);
  });

  test('friends() covers more than 30 authors and includes me', () async {
    final friends = [for (var i = 0; i < 40; i++) 'f$i'];
    for (var i = 0; i < 40; i++) {
      await db.collection('posts').doc('f${i}_p').set(postDoc('f$i', i));
    }
    await db.collection('posts').doc('me_p').set(postDoc('me', 50));
    await db.collection('posts').doc('stranger_p').set(postDoc('zz', 55));
    final pager = repo.friends(friends);
    final all = <Post>[];
    while (pager.hasMore) {
      all.addAll(await pager.next(7));
    }
    expect(all, hasLength(41));
    expect(all.first.id, 'me_p');
    expect(all.last.id, 'f0_p');
    expect(all.map((p) => p.id).toSet(), hasLength(41));
    expect(all.any((p) => p.authorUid == 'zz'), isFalse);
  });

  test('postsBy() hides friends-only posts unless allowed', () async {
    await db.collection('posts').doc('a_1').set(postDoc('a', 1));
    await db
        .collection('posts')
        .doc('a_2')
        .set(postDoc('a', 2, visibility: 'friends'));
    await db.collection('posts').doc('a_3').set(postDoc('a', 3, type: 'quote'));
    Future<List<String>> ids(bool friends, {PostType? type}) async =>
        (await repo
                .postsBy('a', includeFriendsOnly: friends, type: type)
                .next(10))
            .map((p) => p.id)
            .toList();
    expect(await ids(false), ['a_3', 'a_1']);
    expect(await ids(true), ['a_3', 'a_2', 'a_1']);
    expect(await ids(true, type: PostType.quote), ['a_3']);
  });

  test('shelf and badges read the public profile collections', () async {
    final library = db.collection('users').doc('a').collection('library');
    await library.doc('k1').set({
      'bookKey': 'k1',
      'title': 'Emma',
      'author': 'Jane Austen',
      'shelf': 'currentlyReading',
      'progress': 47.5,
      'coverUrl': 'https://example.com/1.jpg',
      'deleted': false,
    });
    await library.doc('k2').set({'title': 'Old', 'deleted': true});
    final shelf = await repo.watchShelf('a').first;
    expect(shelf, hasLength(2));
    final grouped = ShelfEntry.group(shelf);
    expect(grouped[Shelf.currentlyReading]!.single.progress, 47.5);
    expect(grouped[Shelf.wantToRead], isEmpty);
    expect(shelf.firstWhere((e) => e.bookKey == 'k2').deleted, isTrue);

    final badges = db.collection('users').doc('a').collection('badges');
    await badges.doc('bookworm').set({
      'badgeId': 'bookworm',
      'unlockedAt': Timestamp.fromDate(DateTime(2026, 2)),
    });
    await badges.doc('first_chapter').set({
      'unlockedAt': Timestamp.fromDate(DateTime(2026, 3)),
    });
    final unlocked = await repo.watchBadges('a').first;
    expect(unlocked.map((b) => b.badgeId), ['first_chapter', 'bookworm']);

    // Missing collections are simply empty.
    expect(await repo.watchShelf('nobody').first, isEmpty);
    expect(await repo.watchBadges('nobody').first, isEmpty);
  });
}
