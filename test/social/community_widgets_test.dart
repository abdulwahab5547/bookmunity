import 'package:bookmunity/design/brutal_theme.dart';
import 'package:bookmunity/features/social/data/community_models.dart';
import 'package:bookmunity/features/social/data/community_providers.dart';
import 'package:bookmunity/features/social/data/community_repository.dart';
import 'package:bookmunity/features/social/data/social_models.dart';
import 'package:bookmunity/features/social/data/social_providers.dart';
import 'package:bookmunity/features/social/data/social_repository.dart';
import 'package:bookmunity/features/social/presentation/book_page_screen.dart';
import 'package:bookmunity/features/social/presentation/community_screen.dart';
import 'package:bookmunity/features/social/presentation/community_widgets.dart';
import 'package:bookmunity/features/social/presentation/friend_profile_screen.dart';
import 'package:bookmunity/features/social/presentation/post_detail_screen.dart';
import 'package:bookmunity/features/social/presentation/share_quote_sheet.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const book = BookRef(
  bookKey: 'dracula|bram-stoker',
  title: 'Dracula',
  author: 'Bram Stoker',
);

Map<String, Object?> profileDoc(String uid, String name) => {
  'uid': uid,
  'username': name.toLowerCase(),
  'usernameLower': name.toLowerCase(),
  'displayName': name,
  'booksFinished': 3,
  'currentStreak': 2,
  'longestStreak': 5,
  'badgeCount': 1,
  'bio': 'Reads at night.',
  'createdAt': Timestamp.fromDate(DateTime(2026, 1, 1)),
};

/// One post of every type by "ana", newest first by minute.
Future<void> seed(FakeFirebaseFirestore db) async {
  await db.collection('profiles').doc('me').set(profileDoc('me', 'Me'));
  await db.collection('profiles').doc('ana').set(profileDoc('ana', 'Ana'));
  final drafts = [
    const PostDraft(type: PostType.started, book: book),
    const PostDraft(type: PostType.finished, book: book, text: 'What a ride'),
    const PostDraft(type: PostType.shelved, book: book),
    const PostDraft(type: PostType.progress, book: book, progress: 50),
    PostDraft(
      type: PostType.review,
      book: book,
      rating: 4,
      text: 'A long review. ' * 30,
    ),
    const PostDraft(type: PostType.rating, book: book, rating: 2),
    PostDraft(
      type: PostType.quote,
      book: book,
      quote: 'Listen to them, the children of the night. ' * 4,
      text: 'Chills.',
      chapter: 'Chapter 2',
    ),
    const PostDraft(
      type: PostType.badge,
      badgeId: 'bookworm',
      badgeTitle: 'Bookworm',
    ),
  ];
  for (var i = 0; i < drafts.length; i++) {
    await db.collection('posts').doc('ana_$i').set({
      ...drafts[i].toCreateMap(person('ana', 'Ana')),
      'createdAt': Timestamp.fromDate(
        DateTime.now().subtract(Duration(minutes: 60 - i)),
      ),
      'updatedAt': Timestamp.now(),
    });
  }
}

Profile person(String uid, String name) => Profile(
  uid: uid,
  username: name.toLowerCase(),
  displayName: name,
  booksFinished: 0,
  currentStreak: 0,
  longestStreak: 0,
  badgeCount: 0,
);

Future<FakeFirebaseFirestore> pumpApp(
  WidgetTester tester,
  Widget home, {
  bool dark = false,
  double width = 320,
  double height = 700,
  FakeFirebaseFirestore? db,
}) async {
  final firestore = db ?? FakeFirebaseFirestore();
  if (db == null) await seed(firestore);
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        socialRepositoryProvider.overrideWithValue(
          SocialRepository(firestore, 'me'),
        ),
        communityRepositoryProvider.overrideWithValue(
          CommunityRepository(firestore, 'me'),
        ),
      ],
      child: MaterialApp(
        theme: brutalTheme(dark: false),
        darkTheme: brutalTheme(dark: true),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return firestore;
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'Community feed shows every post type at 320dp (${dark ? 'dark' : 'light'})',
      (tester) async {
        await pumpApp(tester, const CommunityScreen(), dark: dark);
        expect(find.text('Friends'), findsOneWidget);
        expect(find.text('Everyone'), findsOneWidget);
        // No friends yet: the Friends tab still shows my and nobody else's
        // posts, so it is empty and points at the people screen.
        expect(find.text('Find your people'), findsOneWidget);

        await tester.tap(find.text('Everyone'));
        await tester.pumpAndSettle();
        // Newest first: the badge post.
        expect(
          find.textContaining('earned the Bookworm badge'),
          findsOneWidget,
        );

        // Scroll through every card; nothing may overflow.
        for (final verb in [
          'shared a quote from',
          'rated',
          'reviewed',
          'is 50% through',
          'wants to read',
          'finished reading',
          'started reading',
        ]) {
          await tester.scrollUntilVisible(
            find.textContaining(verb),
            300,
            scrollable: find.byType(Scrollable).last,
          );
          expect(find.textContaining(verb), findsWidgets);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Like toggles a reaction and the picker changes it', (
    tester,
  ) async {
    final db = await pumpApp(tester, const CommunityScreen());
    await tester.tap(find.text('Everyone'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('👍 Like').first);
    await tester.pumpAndSettle();
    var post = await db.collection('posts').doc('ana_7').get();
    expect(post.data()!['reactions']['like'], 1);
    expect(find.text('👍 1'), findsOneWidget);

    await tester.tap(find.byTooltip('More reactions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('❤️'));
    await tester.pumpAndSettle();
    post = await db.collection('posts').doc('ana_7').get();
    expect(post.data()!['reactions'], containsPair('love', 1));
    expect(post.data()!['reactions'], containsPair('like', 0));
    expect(find.text('❤️ Love'), findsOneWidget);

    // Tapping again removes it.
    await tester.tap(find.text('❤️ Love'));
    await tester.pumpAndSettle();
    post = await db.collection('posts').doc('ana_7').get();
    expect(post.data()!['reactions']['love'], 0);
  });

  testWidgets('Post page: comment, reply and delete', (tester) async {
    final db = await pumpApp(
      tester,
      const PostDetailScreen(postId: 'ana_6'),
      height: 1600,
    );
    expect(
      find.text('No comments yet. Start the conversation.'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'Great quote');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('Great quote'), findsOneWidget);
    expect(find.text('Comments (1)'), findsOneWidget);

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Me'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Replying to myself');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('Replying to myself'), findsOneWidget);
    final comments = await db
        .collection('posts')
        .doc('ana_6')
        .collection('comments')
        .get();
    final reply = comments.docs.firstWhere(
      (d) => d.data()['text'] == 'Replying to myself',
    );
    expect(reply.data()['parentId'], isNotEmpty);
    expect(
      (await db.collection('posts').doc('ana_6').get()).data()!['commentCount'],
      2,
    );

    // Deleting the top-level comment takes its reply with it.
    await tester.tap(find.text('Delete').first);
    await tester.pumpAndSettle();
    expect(find.text('Its 1 reply is deleted too.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Delete').last);
    await tester.pumpAndSettle();
    expect(find.text('Great quote'), findsNothing);
    expect(
      (await db.collection('posts').doc('ana_6').get()).data()!['commentCount'],
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Own posts can be deleted from the card menu', (tester) async {
    final db = FakeFirebaseFirestore();
    await seed(db);
    await db.collection('posts').doc('me_q').set({
      ...const PostDraft(
        type: PostType.quote,
        book: book,
        quote: 'Mine',
      ).toCreateMap(person('me', 'Me')),
      'createdAt': Timestamp.now(),
    });
    await pumpApp(tester, const CommunityScreen(), db: db);
    expect(find.text('“Mine”'), findsOneWidget);
    await tester.tap(find.byTooltip('Post options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete post'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect((await db.collection('posts').doc('me_q').get()).exists, isFalse);
    expect(find.text('“Mine”'), findsNothing);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'Reader profile shows shelves, badges and posts (${dark ? 'dark' : 'light'})',
      (tester) async {
        final db = FakeFirebaseFirestore();
        await seed(db);
        final library = db.collection('users').doc('ana').collection('library');
        await library.doc('a').set({
          'bookKey': 'dracula|bram-stoker',
          'title': 'Dracula',
          'author': 'Bram Stoker',
          'shelf': 'currentlyReading',
          'progress': 64,
          'deleted': false,
        });
        await library.doc('b').set({
          'bookKey': 'emma|jane-austen',
          'title': 'Emma',
          'shelf': 'finished',
          'progress': 100,
          'deleted': false,
        });
        await db
            .collection('users')
            .doc('ana')
            .collection('badges')
            .doc('bookworm')
            .set({'badgeId': 'bookworm', 'unlockedAt': Timestamp.now()});
        await pumpApp(
          tester,
          const FriendProfileScreen(uid: 'ana'),
          db: db,
          dark: dark,
        );
        expect(find.text('Ana'), findsWidgets);
        expect(find.text('Add friend'), findsOneWidget);
        expect(find.text('Currently reading (1)'), findsOneWidget);
        expect(find.text('64%'), findsOneWidget);
        final list = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text('Read (1)'),
          200,
          scrollable: list,
        );
        await tester.scrollUntilVisible(
          find.text('Want to read (0)'),
          200,
          scrollable: list,
        );
        await tester.scrollUntilVisible(
          find.text('Badges (1)'),
          200,
          scrollable: list,
        );
        expect(find.text('Bookworm'), findsWidgets);

        await tester.scrollUntilVisible(
          find.text('Updates'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Quotes'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Book page lists reviews and quotes for any book key', (
    tester,
  ) async {
    final db = FakeFirebaseFirestore();
    await seed(db);
    await db
        .collection('books')
        .doc(book.bookKey)
        .collection('reviews')
        .doc('ana')
        .set({
          'uid': 'ana',
          'username': 'ana',
          'displayName': 'Ana',
          'rating': 4,
          'text': 'Creepy and fun.',
          'updatedAt': Timestamp.now(),
        });
    await db.collection('posts').doc('ana_6').update({'visibility': 'public'});
    await pumpApp(tester, const BookPageScreen(book: book), db: db);
    expect(find.text('Dracula'), findsWidgets);
    expect(find.text('Bram Stoker'), findsWidgets);
    expect(find.text('Creepy and fun.'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Chills.'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Share quote sheet returns the note and audience', (
    tester,
  ) async {
    QuoteShare? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: brutalTheme(dark: false),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showShareQuoteSheet(
              context,
              quote: 'Q',
              note: 'n',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('“Q”'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'My note');
    await tester.tap(find.text('Friends only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(result?.note, 'My note');
    expect(result?.visibility, PostVisibility.friends);
  });

  testWidgets('StarRating shows half stars', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: StarRating(rating: 3.5)));
    expect(find.byIcon(Icons.star_rounded), findsNWidgets(3));
    expect(find.byIcon(Icons.star_half_rounded), findsOneWidget);
    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
  });
}
