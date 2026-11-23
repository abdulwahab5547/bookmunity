import 'package:bookmunity/features/social/data/community_models.dart';
import 'package:bookmunity/features/social/data/feed_pager.dart';
import 'package:bookmunity/features/social/data/social_models.dart';
import 'package:bookmunity/features/social/presentation/community_widgets.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

const me = Profile(
  uid: 'u1',
  username: 'reader',
  displayName: 'A Reader',
  booksFinished: 0,
  currentStreak: 0,
  longestStreak: 0,
  badgeCount: 0,
);

const book = BookRef(
  bookKey: 'dracula|bram-stoker',
  title: 'Dracula',
  author: 'Bram Stoker',
  coverUrl: 'https://example.com/c.jpg',
);

void main() {
  group('Post.fromMap', () {
    test('parses every field and keeps only non-zero reactions', () {
      final post = Post.fromMap('u1_x', {
        'authorUid': 'u1',
        'authorUsername': 'reader',
        'authorDisplayName': 'A Reader',
        'type': 'quote',
        'visibility': 'friends',
        'bookKey': 'dracula|bram-stoker',
        'title': 'Dracula',
        'author': 'Bram Stoker',
        'quote': 'Listen to them',
        'text': 'Spooky',
        'chapter': 'Chapter 2',
        'reactions': {'like': 3, 'love': 0, 'wow': 1, 'bogus': 9},
        'commentCount': 4,
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 1, 2)),
      })!;
      expect(post.type, PostType.quote);
      expect(post.visibility, PostVisibility.friends);
      expect(post.reactions, {ReactionType.like: 3, ReactionType.wow: 1});
      expect(post.reactionTotal, 4);
      expect(post.topReactions.first, ReactionType.like);
      expect(post.commentCount, 4);
      expect(post.createdAt!.isAtSameMomentAs(DateTime.utc(2026, 1, 2)), isTrue);
      expect(post.book?.title, 'Dracula');
    });

    test('ignores unknown types and tolerates junk', () {
      expect(Post.fromMap('x', {'type': 'poll'}), isNull);
      final post = Post.fromMap('x', {
        'type': 'review',
        'rating': 42,
        'reactions': 'nope',
        'title': 7,
      })!;
      expect(post.rating, 5);
      expect(post.reactions, isEmpty);
      expect(post.title, '');
      expect(post.visibility, PostVisibility.public);
    });

    test('badge posts have no book', () {
      final post = Post.fromMap('x', {
        'type': 'badge',
        'bookKey': 'should-not-matter',
        'badgeTitle': 'Bookworm',
      })!;
      expect(post.book, isNull);
    });

    test('withReaction moves counts for optimistic updates', () {
      final post = Post.fromMap('x', {
        'type': 'quote',
        'reactions': {'like': 1, 'love': 2},
      })!;
      final changed = post.withReaction(ReactionType.like, ReactionType.wow);
      expect(changed.reactions, {ReactionType.love: 2, ReactionType.wow: 1});
      final removed = changed.withReaction(ReactionType.wow, null);
      expect(removed.reactions, {ReactionType.love: 2});
    });
  });

  group('PostDraft', () {
    test('create map matches what the rules require', () {
      final map = const PostDraft(
        type: PostType.review,
        book: book,
        rating: 9,
        text: '  Great  ',
        quote: 'ignored',
        progress: 50,
        badgeId: 'ignored',
      ).toCreateMap(me);
      expect(map['authorUid'], 'u1');
      expect(map['authorUsername'], 'reader');
      expect(map['rating'], 5);
      expect(map['text'], 'Great');
      expect(map['quote'], '');
      expect(map['progress'], 0);
      expect(map['badgeId'], '');
      expect(map['reactions'], {
        'like': 0,
        'love': 0,
        'haha': 0,
        'wow': 0,
        'sad': 0,
      });
      expect(map['commentCount'], 0);
      expect(map['commentOpId'], '');
      expect(map['createdAt'], isA<FieldValue>());
    });

    test('ratings carry no text and quotes are clipped', () {
      final rating = const PostDraft(
        type: PostType.rating,
        book: book,
        rating: 0,
        text: 'dropped',
      ).contentMap();
      expect(rating['text'], '');
      expect(rating['rating'], 1);

      final quote = PostDraft(
        type: PostType.quote,
        book: book,
        quote: 'q' * 5000,
        text: 'n' * 5000,
      ).contentMap();
      expect(quote['quote'], hasLength(CommunityLimits.quote));
      expect(quote['text'], hasLength(CommunityLimits.text));
      expect(quote['rating'], 0);
    });

    test('update map never touches counters or authorship', () {
      final map = const PostDraft(
        type: PostType.rating,
        book: book,
        rating: 3,
      ).toUpdateMap(me);
      expect(
        map.keys,
        isNot(
          anyOf(
            contains('reactions'),
            contains('commentCount'),
            contains('authorUid'),
            contains('createdAt'),
          ),
        ),
      );
    });

    test('book keys are made safe for document ids', () {
      final map = const PostDraft(
        type: PostType.started,
        book: BookRef(bookKey: 'a/b|c', title: ''),
      ).contentMap();
      expect(map['bookKey'], 'a-b|c');
      expect(map['title'], 'Untitled');
    });
  });

  test('post ids start with the author uid', () {
    expect(PostIds.review('u1', 'a/b'), 'u1_review_a-b');
    expect(
      PostIds.update('u1', PostType.finished, 'x|y'),
      'u1_finished_x|y',
    );
    expect(PostIds.badge('u1', 'bookworm'), 'u1_badge_bookworm');
    expect(PostIds.random('u1', 'abc'), 'u1_abc');
  });

  test('comments group into one level of threads', () {
    PostComment c(String id, [String parent = '']) => PostComment(
      id: id,
      authorUid: 'u',
      authorUsername: 'u',
      authorDisplayName: 'U',
      text: id,
      parentId: parent,
    );
    final threads = CommentThread.group([
      c('a'),
      c('r1', 'a'),
      c('b'),
      c('r2', 'a'),
      c('orphan', 'gone'),
    ]);
    expect(threads.map((t) => t.comment.id), ['a', 'b']);
    expect(threads.first.replies.map((r) => r.id), ['r1', 'r2']);
    expect(threads.last.replies, isEmpty);
  });

  test('shelf entries group by shelf, newest first, without deleted', () {
    ShelfEntry e(String key, Shelf shelf, int day, {bool deleted = false}) =>
        ShelfEntry(
          bookKey: key,
          title: key,
          author: '',
          shelf: shelf,
          deleted: deleted,
          updatedAt: DateTime(2026, 1, day),
        );
    final grouped = ShelfEntry.group([
      e('old', Shelf.finished, 1),
      e('new', Shelf.finished, 5),
      e('gone', Shelf.finished, 9, deleted: true),
      e('want', Shelf.wantToRead, 2),
    ]);
    expect(grouped[Shelf.finished]!.map((x) => x.bookKey), ['new', 'old']);
    expect(grouped[Shelf.wantToRead], hasLength(1));
    expect(grouped[Shelf.currentlyReading], isEmpty);
    expect(Shelf.parse('nonsense'), Shelf.wantToRead);
  });

  test('timeAgo is short and falls back to a date', () {
    final now = DateTime(2026, 3, 10, 12);
    expect(timeAgo(null), 'now');
    expect(timeAgo(now.subtract(const Duration(seconds: 20)), now: now), 'now');
    expect(timeAgo(now.subtract(const Duration(minutes: 5)), now: now), '5m');
    expect(timeAgo(now.subtract(const Duration(hours: 3)), now: now), '3h');
    expect(timeAgo(now.subtract(const Duration(days: 2)), now: now), '2d');
    expect(timeAgo(DateTime(2026, 1, 1), now: now), '1 Jan 2026');
  });

  group('MergedPager', () {
    test('merges sources newest first with no gaps or repeats', () async {
      // Three sources with interleaved times (higher = newer).
      final sources = [
        _ListSource([100, 97, 60, 10]),
        _ListSource([99, 98, 50, 40, 30]),
        _ListSource([70]),
      ];
      final pager = MergedPager<int>(
        sources,
        timeOf: (value) => DateTime.fromMillisecondsSinceEpoch(value),
      );
      final pages = <List<int>>[];
      while (pager.hasMore) {
        pages.add(await pager.next(3));
      }
      expect(pages.expand((p) => p), [100, 99, 98, 97, 70, 60, 50, 40, 30, 10]);
      expect(pages.first, [100, 99, 98]);
      // Each source is asked for small pages only.
      expect(sources.every((s) => s.requests.every((n) => n == 3)), isTrue);
    });

    test('empty sources end the feed', () async {
      final pager = MergedPager<int>([
        _ListSource([]),
      ], timeOf: (_) => null);
      expect(await pager.next(5), isEmpty);
      expect(pager.hasMore, isFalse);
    });

    test('chunked splits for whereIn', () {
      expect(chunked(List.generate(65, (i) => i), 30).map((c) => c.length), [
        30,
        30,
        5,
      ]);
      expect(chunked(<int>[], 30), isEmpty);
    });
  });
}

class _ListSource implements PagedSource<int> {
  _ListSource(this.values);

  final List<int> values;
  final requests = <int>[];
  var _offset = 0;

  @override
  Future<SourcePage<int>> fetch(int count) async {
    requests.add(count);
    final end = (_offset + count).clamp(0, values.length);
    final page = values.sublist(_offset, end);
    _offset = end;
    return SourcePage(page, exhausted: end >= values.length);
  }
}
