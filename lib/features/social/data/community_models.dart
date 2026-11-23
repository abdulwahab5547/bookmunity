import 'package:cloud_firestore/cloud_firestore.dart';

import 'social_models.dart';

// Community data: posts, reactions, comments, public bookshelves and
// badges. Field names and limits mirror the "Community" block in
// firestore.rules; change both together. See docs/cloud-data.md.

DateTime? _time(Object? value) => value is Timestamp ? value.toDate() : null;

String _str(Object? value) => value is String ? value : '';

int _int(Object? value) => value is num ? value.toInt() : 0;

String _clip(String value, int max) {
  final trimmed = value.trim();
  return trimmed.length > max ? trimmed.substring(0, max) : trimmed;
}

/// Limits enforced by firestore.rules.
abstract final class CommunityLimits {
  static const text = 2000;
  static const quote = 1000;
  static const comment = 1000;
  static const chapter = 200;
  static const badge = 60;
  static const coverUrl = 500;

  /// Firestore `whereIn` accepts at most 30 values.
  static const whereInChunk = 30;
}

enum PostType {
  /// Moved a book to "Currently reading".
  started,

  /// Finished a book.
  finished,

  /// Added a book to "Want to read".
  shelved,

  /// Reached a progress milestone (50%).
  progress,

  /// Star rating with a written review.
  review,

  /// Star rating without text.
  rating,

  /// A highlighted passage with an optional note.
  quote,

  /// Earned an achievement badge.
  badge;

  static PostType? parse(Object? value) {
    for (final type in values) {
      if (type.name == value) return type;
    }
    return null;
  }

  bool get isAboutBook => this != badge;
}

enum PostVisibility {
  /// Any signed-in reader ("Everyone").
  public,

  /// Only the author's friends.
  friends;

  static PostVisibility parse(Object? value) =>
      value == friends.name ? friends : public;

  String get label => switch (this) {
    public => 'Everyone',
    friends => 'Friends only',
  };
}

/// Goodreads/Facebook-style reactions. One per reader per post.
enum ReactionType {
  like('👍', 'Like'),
  love('❤️', 'Love'),
  haha('😂', 'Haha'),
  wow('😮', 'Wow'),
  sad('😢', 'Sad');

  const ReactionType(this.emoji, this.label);

  final String emoji;
  final String label;

  static ReactionType? parse(Object? value) {
    for (final type in values) {
      if (type.name == value) return type;
    }
    return null;
  }

  /// A post's counter map with every reaction at zero (required on create).
  static Map<String, int> get zeroCounts => {
    for (final type in values) type.name: 0,
  };
}

/// The book a post, shelf entry or review is about. Enough to open the book
/// page without the book being in the local library.
class BookRef {
  const BookRef({
    required this.bookKey,
    required this.title,
    this.author = '',
    this.coverUrl = '',
  });

  final String bookKey;
  final String title;
  final String author;
  final String coverUrl;

  /// Firestore document id for `books/{id}` (no `/`, at most 200 chars).
  String get docKey => reviewDocKey(bookKey);

  @override
  bool operator ==(Object other) =>
      other is BookRef && other.bookKey == bookKey;

  @override
  int get hashCode => bookKey.hashCode;
}

class Post {
  const Post({
    required this.id,
    required this.authorUid,
    required this.authorUsername,
    required this.authorDisplayName,
    required this.type,
    this.visibility = PostVisibility.public,
    this.bookKey = '',
    this.title = '',
    this.author = '',
    this.coverUrl = '',
    this.rating = 0,
    this.text = '',
    this.quote = '',
    this.chapter = '',
    this.progress = 0,
    this.badgeId = '',
    this.badgeTitle = '',
    this.reactions = const {},
    this.commentCount = 0,
    this.createdAt,
    this.updatedAt,
  });

  /// Returns null for documents of an unknown type (e.g. from a newer app).
  static Post? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) return null;
    return fromMap(doc.id, data);
  }

  static Post? fromMap(String id, Map<String, dynamic> data) {
    final type = PostType.parse(data['type']);
    if (type == null) return null;
    final rawReactions = data['reactions'];
    return Post(
      id: id,
      authorUid: _str(data['authorUid']),
      authorUsername: _str(data['authorUsername']),
      authorDisplayName: _str(data['authorDisplayName']),
      type: type,
      visibility: PostVisibility.parse(data['visibility']),
      bookKey: _str(data['bookKey']),
      title: _str(data['title']),
      author: _str(data['author']),
      coverUrl: _str(data['coverUrl']),
      rating: _int(data['rating']).clamp(0, 5),
      text: _str(data['text']),
      quote: _str(data['quote']),
      chapter: _str(data['chapter']),
      progress: _int(data['progress']).clamp(0, 100),
      badgeId: _str(data['badgeId']),
      badgeTitle: _str(data['badgeTitle']),
      reactions: {
        if (rawReactions is Map)
          for (final type in ReactionType.values)
            if (_int(rawReactions[type.name]) > 0)
              type: _int(rawReactions[type.name]),
      },
      commentCount: _int(data['commentCount']).clamp(0, 1 << 31),
      createdAt: _time(data['createdAt']),
      updatedAt: _time(data['updatedAt']),
    );
  }

  final String id;
  final String authorUid;
  final String authorUsername;
  final String authorDisplayName;
  final PostType type;
  final PostVisibility visibility;
  final String bookKey;
  final String title;
  final String author;
  final String coverUrl;

  /// 1..5 for reviews and ratings, 0 otherwise.
  final int rating;

  /// Review text, or the reader's note on a quote or update.
  final String text;

  /// The highlighted passage (quotes only).
  final String quote;
  final String chapter;

  /// Percent reached (progress updates only).
  final int progress;
  final String badgeId;
  final String badgeTitle;

  /// Reaction counts, only types with at least one reaction.
  final Map<ReactionType, int> reactions;
  final int commentCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  int get reactionTotal => reactions.values.fold(0, (total, n) => total + n);

  /// Most used reactions first (for the summary under a post).
  List<ReactionType> get topReactions {
    final entries = reactions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final entry in entries) entry.key];
  }

  BookRef? get book => type.isAboutBook && bookKey.isNotEmpty
      ? BookRef(
          bookKey: bookKey,
          title: title,
          author: author,
          coverUrl: coverUrl,
        )
      : null;

  /// Counts as they will be once [mine] changes from [before] to [after];
  /// used for optimistic updates.
  Post withReaction(ReactionType? before, ReactionType? after) {
    final next = Map<ReactionType, int>.of(reactions);
    if (before != null) {
      final value = (next[before] ?? 0) - 1;
      if (value > 0) {
        next[before] = value;
      } else {
        next.remove(before);
      }
    }
    if (after != null) next[after] = (next[after] ?? 0) + 1;
    return copyWith(reactions: next);
  }

  Post copyWith({Map<ReactionType, int>? reactions, int? commentCount}) => Post(
    id: id,
    authorUid: authorUid,
    authorUsername: authorUsername,
    authorDisplayName: authorDisplayName,
    type: type,
    visibility: visibility,
    bookKey: bookKey,
    title: title,
    author: author,
    coverUrl: coverUrl,
    rating: rating,
    text: text,
    quote: quote,
    chapter: chapter,
    progress: progress,
    badgeId: badgeId,
    badgeTitle: badgeTitle,
    reactions: reactions ?? this.reactions,
    commentCount: commentCount ?? this.commentCount,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// What the app wants to publish; turned into the exact document the rules
/// accept by [toCreateMap] / [toUpdateMap].
class PostDraft {
  const PostDraft({
    required this.type,
    this.visibility = PostVisibility.public,
    this.book,
    this.rating = 0,
    this.text = '',
    this.quote = '',
    this.chapter = '',
    this.progress = 0,
    this.badgeId = '',
    this.badgeTitle = '',
  });

  final PostType type;
  final PostVisibility visibility;
  final BookRef? book;
  final int rating;
  final String text;
  final String quote;
  final String chapter;
  final int progress;
  final String badgeId;
  final String badgeTitle;

  /// Content fields, clipped to the rule limits.
  Map<String, Object> contentMap() {
    final book = this.book;
    final isRated = type == PostType.review || type == PostType.rating;
    return {
      'type': type.name,
      'visibility': visibility.name,
      'bookKey': book == null ? '' : clipTitle(book.docKey),
      'title': book == null
          ? ''
          : clipTitle(book.title.trim().isEmpty ? 'Untitled' : book.title),
      'author': book == null ? '' : clipTitle(book.author.trim()),
      'coverUrl': book == null ? '' : _clip(book.coverUrl, 500),
      'rating': isRated ? rating.clamp(1, 5) : 0,
      'text': type == PostType.rating ? '' : _clip(text, CommunityLimits.text),
      'quote': type == PostType.quote
          ? _clip(quote, CommunityLimits.quote)
          : '',
      'chapter': _clip(chapter, CommunityLimits.chapter),
      'progress': type == PostType.progress ? progress.clamp(1, 99) : 0,
      'badgeId': type == PostType.badge
          ? _clip(badgeId, CommunityLimits.badge)
          : '',
      'badgeTitle': type == PostType.badge
          ? _clip(badgeTitle, CommunityLimits.badge)
          : '',
    };
  }

  /// A new post by [me]: zero counters, server timestamps.
  Map<String, Object> toCreateMap(Profile me) => {
    'authorUid': me.uid,
    'authorUsername': me.username,
    'authorDisplayName': me.displayName,
    ...contentMap(),
    'reactions': ReactionType.zeroCounts,
    'commentCount': 0,
    'commentOpId': '',
    'createdAt': FieldValue.serverTimestamp(),
    'updatedAt': FieldValue.serverTimestamp(),
  };

  /// Editing an existing post: content only, counters untouched.
  Map<String, Object> toUpdateMap(Profile me) => {
    'authorDisplayName': me.displayName,
    ...contentMap(),
    'updatedAt': FieldValue.serverTimestamp(),
  };
}

/// Post ids always start with the author's uid (the rules require it), so
/// nobody can claim the id of someone else's deterministic post.
abstract final class PostIds {
  /// One review/rating post per reader per book: saving again updates it.
  static String review(String uid, String bookKey) =>
      '${uid}_review_${reviewDocKey(bookKey)}';

  /// One "started"/"finished"/"shelved"/"halfway" post per reader per book,
  /// so toggling a shelf does not flood the feed.
  static String update(String uid, PostType type, String bookKey) =>
      '${uid}_${type.name}_${reviewDocKey(bookKey)}';

  static String badge(String uid, String badgeId) => '${uid}_badge_$badgeId';

  /// Quotes can be shared any number of times.
  static String random(String uid, String autoId) => '${uid}_$autoId';
}

class Reaction {
  const Reaction({
    required this.uid,
    required this.type,
    required this.username,
    required this.displayName,
  });

  static Reaction? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final type = ReactionType.parse(data?['type']);
    if (data == null || type == null) return null;
    return Reaction(
      uid: doc.id,
      type: type,
      username: _str(data['username']),
      displayName: _str(data['displayName']),
    );
  }

  final String uid;
  final ReactionType type;
  final String username;
  final String displayName;
}

class PostComment {
  const PostComment({
    required this.id,
    required this.authorUid,
    required this.authorUsername,
    required this.authorDisplayName,
    required this.text,
    this.parentId = '',
    this.createdAt,
  });

  factory PostComment.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    return PostComment(
      id: doc.id,
      authorUid: _str(data['authorUid']),
      authorUsername: _str(data['authorUsername']),
      authorDisplayName: _str(data['authorDisplayName']),
      text: _str(data['text']),
      parentId: _str(data['parentId']),
      createdAt: _time(data['createdAt']),
    );
  }

  final String id;
  final String authorUid;
  final String authorUsername;
  final String authorDisplayName;
  final String text;

  /// Empty for a top-level comment, otherwise the comment it replies to.
  final String parentId;
  final DateTime? createdAt;

  bool get isReply => parentId.isNotEmpty;
}

/// A top-level comment with its replies (one level of threading).
class CommentThread {
  const CommentThread(this.comment, this.replies);

  final PostComment comment;
  final List<PostComment> replies;

  /// Groups a flat, oldest-first list. Replies whose parent is gone are
  /// dropped (the parent's deletion removes them too).
  static List<CommentThread> group(List<PostComment> comments) {
    final replies = <String, List<PostComment>>{};
    for (final comment in comments.where((c) => c.isReply)) {
      replies.putIfAbsent(comment.parentId, () => []).add(comment);
    }
    return [
      for (final comment in comments.where((c) => !c.isReply))
        CommentThread(comment, replies[comment.id] ?? const []),
    ];
  }
}

enum Shelf {
  wantToRead('Want to read'),
  currentlyReading('Currently reading'),
  finished('Read');

  const Shelf(this.label);

  final String label;

  static Shelf parse(Object? value) {
    for (final shelf in values) {
      if (shelf.name == value) return shelf;
    }
    return Shelf.wantToRead;
  }
}

/// A book on a reader's public shelf: `users/{uid}/library/{bookKey}`,
/// written by the sync feature (read-only here).
class ShelfEntry {
  const ShelfEntry({
    required this.bookKey,
    required this.title,
    required this.author,
    required this.shelf,
    this.progress = 0,
    this.coverUrl = '',
    this.coverPath,
    this.deleted = false,
    this.addedAt,
    this.finishedAt,
    this.updatedAt,
  });

  factory ShelfEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    final key = _str(data['bookKey']);
    final progress = data['progress'];
    return ShelfEntry(
      bookKey: key.isEmpty ? doc.id : key,
      title: _str(data['title']),
      author: _str(data['author']),
      shelf: Shelf.parse(data['shelf']),
      progress: progress is num
          ? progress.toDouble().clamp(0, 100).toDouble()
          : 0,
      coverUrl: _str(data['coverUrl']),
      deleted: data['deleted'] == true,
      addedAt: _time(data['addedAt']),
      finishedAt: _time(data['finishedAt']),
      updatedAt: _time(data['updatedAt']),
    );
  }

  final String bookKey;
  final String title;
  final String author;
  final Shelf shelf;

  /// 0..100.
  final double progress;
  final String coverUrl;

  /// Local cover file (only for the user's own books on this device).
  final String? coverPath;
  final bool deleted;
  final DateTime? addedAt;
  final DateTime? finishedAt;
  final DateTime? updatedAt;

  BookRef get book => BookRef(
    bookKey: bookKey,
    title: title.isEmpty ? 'Untitled' : title,
    author: author,
    coverUrl: coverUrl,
  );

  /// Live entries grouped by shelf, most recently touched first.
  static Map<Shelf, List<ShelfEntry>> group(Iterable<ShelfEntry> entries) {
    final result = {for (final shelf in Shelf.values) shelf: <ShelfEntry>[]};
    for (final entry in entries) {
      if (!entry.deleted) result[entry.shelf]!.add(entry);
    }
    DateTime when(ShelfEntry e) =>
        e.finishedAt ?? e.updatedAt ?? e.addedAt ?? DateTime(0);
    for (final list in result.values) {
      list.sort((a, b) => when(b).compareTo(when(a)));
    }
    return result;
  }
}

/// `users/{uid}/badges/{badgeId}`, written by the achievements sync.
class PublicBadge {
  const PublicBadge({required this.badgeId, this.unlockedAt});

  factory PublicBadge.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    final id = _str(data['badgeId']);
    return PublicBadge(
      badgeId: id.isEmpty ? doc.id : id,
      unlockedAt: _time(data['unlockedAt']),
    );
  }

  final String badgeId;
  final DateTime? unlockedAt;
}

/// Review left on `books/{bookKey}/reviews/{uid}`, with the book it is for
/// (for a reader's "ratings" list).
class ReaderReview {
  const ReaderReview({required this.review, required this.book});

  factory ReaderReview.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    final bookDocKey = doc.reference.parent.parent?.id ?? '';
    return ReaderReview(
      review: Review.fromDoc(doc),
      book: BookRef(
        bookKey: bookDocKey,
        title: _str(data['title']),
        author: _str(data['author']),
      ),
    );
  }

  final Review review;
  final BookRef book;
}

/// Average rating and number of ratings, from aggregate queries.
class RatingSummary {
  const RatingSummary({required this.count, required this.average});

  static const empty = RatingSummary(count: 0, average: 0);

  final int count;
  final double average;
}

/// Public reading numbers shown on a profile.
class ReaderStats {
  const ReaderStats({
    required this.friends,
    required this.ratings,
    required this.averageRating,
  });

  static const empty = ReaderStats(friends: 0, ratings: 0, averageRating: 0);

  final int friends;
  final int ratings;
  final double averageRating;
}
