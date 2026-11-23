// Sample readers for testing the social features.
//
// Book keys must match what the app computes on import
// (EpubMetadataExtractor._bookKey: "title-slug|author-slug" unless the EPUB
// carries an ISBN). The first six are the Project Gutenberg EPUB3 editions
// linked in README.md, verified by running the app's extractor on the
// files. The rest are derived the same way from their Gutenberg titles but
// were not run through the extractor; they only appear on shelves, quotes
// and book pages, which work from the key alone.
//
// `gutenberg` is the Project Gutenberg ebook number, used for the cover
// (coverUrl) and download link (sourceUrl) on shelf entries.

export const BOOKS = {
  pride: { key: 'pride-and-prejudice|jane-austen', title: 'Pride and Prejudice', author: 'Jane Austen', gutenberg: 1342 },
  frankenstein: {
    key: 'frankenstein-or-the-modern-prometheus|mary-wollstonecraft-shelley',
    title: 'Frankenstein; or, The modern Prometheus',
    author: 'Mary Wollstonecraft Shelley',
    gutenberg: 84,
  },
  sherlock: {
    key: 'the-adventures-of-sherlock-holmes|arthur-conan-doyle',
    title: 'The Adventures of Sherlock Holmes',
    author: 'Arthur Conan Doyle',
    gutenberg: 1661,
  },
  alice: { key: 'alice-s-adventures-in-wonderland|lewis-carroll', title: "Alice's Adventures in Wonderland", author: 'Lewis Carroll', gutenberg: 11 },
  gatsby: { key: 'the-great-gatsby|f-scott-fitzgerald', title: 'The Great Gatsby', author: 'F. Scott Fitzgerald', gutenberg: 64317 },
  dracula: { key: 'dracula|bram-stoker', title: 'Dracula', author: 'Bram Stoker', gutenberg: 345 },
  mobydick: { key: 'moby-dick-or-the-whale|herman-melville', title: 'Moby Dick; Or, The Whale', author: 'Herman Melville', gutenberg: 2701 },
  janeeyre: { key: 'jane-eyre-an-autobiography|charlotte-bront', title: 'Jane Eyre: An Autobiography', author: 'Charlotte Brontë', gutenberg: 1260 },
  dorian: { key: 'the-picture-of-dorian-gray|oscar-wilde', title: 'The Picture of Dorian Gray', author: 'Oscar Wilde', gutenberg: 174 },
  littlewomen: { key: 'little-women|louisa-may-alcott', title: 'Little Women', author: 'Louisa May Alcott', gutenberg: 514 },
  wuthering: { key: 'wuthering-heights|emily-bront', title: 'Wuthering Heights', author: 'Emily Brontë', gutenberg: 768 },
  twocities: { key: 'a-tale-of-two-cities|charles-dickens', title: 'A Tale of Two Cities', author: 'Charles Dickens', gutenberg: 98 },
  emma: { key: 'emma|jane-austen', title: 'Emma', author: 'Jane Austen', gutenberg: 158 },
  timemachine: { key: 'the-time-machine|h-g-wells', title: 'The Time Machine', author: 'H. G. Wells', gutenberg: 35 },
};

export const coverUrl = (book) =>
  `https://www.gutenberg.org/cache/epub/${book.gutenberg}/pg${book.gutenberg}.cover.medium.jpg`;
export const sourceUrl = (book) => `https://www.gutenberg.org/ebooks/${book.gutenberg}.epub3.images`;

// Badge ids and titles from lib/features/achievements/domain/badges.dart.
export const BADGES = {
  first_chapter: 'First Chapter',
  book_starter: 'Book Starter',
  bookworm: 'Bookworm',
  avid_reader: 'Avid Reader',
  library_legend: 'Library Legend',
  reading_spark: 'Reading Spark',
  steady_reader: 'Steady Reader',
  weekly_reader: 'Weekly Reader',
  dedicated_reader: 'Dedicated Reader',
  reading_habit: 'Reading Habit',
  first_session: 'First Session',
  halfway_there: 'Halfway There',
  finisher: 'Finisher',
  highlight_collector: 'Highlight Collector',
};

// Per reader:
//   stats:   [booksFinished, currentStreak, longestStreak, badgeCount]
//   reviews: [bookId, rating, text]  (empty text = rating only)
//   shelf:   [bookId, shelf, progress, daysAgo]  shelf: wantToRead |
//            currentlyReading | finished. Each becomes a public bookshelf
//            entry; started/finished/shelved/halfway posts are made from it.
//   quotes:  [bookId, passage, note, chapter, visibility?]
//   badges:  badge ids; the first `postBadges` also get a feed post.
export const USERS = [
  {
    username: 'ayesha_reads',
    displayName: 'Ayesha Khan',
    bio: 'Regency romance devotee. Tea, rain and a good Austen.',
    stats: [23, 12, 41, 11],
    reviews: [
      ['pride', 5, 'Elizabeth Bennet is still the sharpest heroine in English fiction. The dialogue sparkles on every reread.'],
      ['gatsby', 4, 'Gorgeous sentences, hollow people — which is exactly the point. The last page gets me every time.'],
      ['alice', 4, 'Pure delightful nonsense. Read it aloud and the wordplay comes alive.'],
      ['emma', 4, ''],
    ],
    shelf: [
      ['pride', 'finished', 100, 20], ['emma', 'finished', 100, 60], ['alice', 'finished', 100, 90],
      ['gatsby', 'currentlyReading', 64, 3], ['janeeyre', 'wantToRead', 0, 5], ['wuthering', 'wantToRead', 0, 12],
    ],
    quotes: [
      ['pride', 'It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.', 'The best opening line ever written. Fight me.', 'Chapter 1'],
      ['emma', 'One half of the world cannot understand the pleasures of the other.', '', 'Chapter 9'],
    ],
    badges: ['weekly_reader', 'first_chapter', 'book_starter', 'bookworm', 'avid_reader', 'reading_spark'],
    postBadges: 1,
  },
  {
    username: 'bilal_pages',
    displayName: 'Bilal Ahmed',
    bio: 'Mysteries before bed, classics on weekends.',
    stats: [9, 3, 15, 7],
    reviews: [
      ['sherlock', 5, 'A Scandal in Bohemia alone is worth it. Holmes and Watson are the original buddy-cop duo.'],
      ['dracula', 4, 'The diary format makes it genuinely creepy. Slow middle, brilliant ending.'],
    ],
    shelf: [
      ['sherlock', 'finished', 100, 15], ['dracula', 'currentlyReading', 41, 2], ['twocities', 'wantToRead', 0, 8],
      ['timemachine', 'wantToRead', 0, 30],
    ],
    quotes: [
      ['sherlock', 'You see, but you do not observe. The distinction is clear.', 'Applies to my code reviews too.', 'A Scandal in Bohemia'],
    ],
    badges: ['first_chapter', 'book_starter', 'bookworm', 'first_session'],
    postBadges: 0,
  },
  {
    username: 'sara_bookworm',
    displayName: 'Sara Malik',
    bio: 'Gothic fiction and very strong coffee.',
    stats: [31, 27, 27, 13],
    reviews: [
      ['frankenstein', 5, 'Not a monster story — a story about loneliness and responsibility. The creature’s chapters are heartbreaking.'],
      ['dracula', 5, 'Atmosphere for days. Reading it at night was a mistake I would make again.'],
      ['pride', 4, 'Witty and warm. Mr Collins made me laugh out loud.'],
      ['wuthering', 5, ''],
    ],
    shelf: [
      ['frankenstein', 'finished', 100, 10], ['dracula', 'finished', 100, 40], ['wuthering', 'finished', 100, 75],
      ['pride', 'finished', 100, 120], ['dorian', 'currentlyReading', 78, 1], ['janeeyre', 'currentlyReading', 22, 6],
      ['mobydick', 'wantToRead', 0, 14],
    ],
    quotes: [
      ['frankenstein', 'I was benevolent and good; misery made me a fiend.', 'The whole novel in one sentence.', 'Chapter 10'],
      ['wuthering', 'Whatever our souls are made of, his and mine are the same.', '', 'Chapter 9'],
      ['dorian', 'The only way to get rid of a temptation is to yield to it.', 'Lord Henry is a terrible influence and I love him.', 'Chapter 2'],
    ],
    badges: ['avid_reader', 'dedicated_reader', 'reading_habit', 'first_chapter', 'book_starter', 'bookworm', 'library_legend'],
    postBadges: 2,
  },
  {
    username: 'hamza_reader',
    displayName: 'Hamza Tariq',
    bio: 'Trying to read 50 books this year. Currently losing.',
    stats: [4, 1, 6, 4],
    reviews: [
      ['gatsby', 3, 'Beautifully written but I couldn’t bring myself to like anyone in it.'],
      ['sherlock', 4, 'Short stories are perfect for a commute. The Red-Headed League is my favourite.'],
    ],
    shelf: [
      ['gatsby', 'finished', 100, 4], ['sherlock', 'finished', 100, 25], ['timemachine', 'currentlyReading', 55, 1],
      ['mobydick', 'wantToRead', 0, 50], ['twocities', 'wantToRead', 0, 2],
    ],
    quotes: [],
    badges: ['first_chapter', 'book_starter', 'first_session', 'halfway_there'],
    postBadges: 1,
  },
  {
    username: 'zainab_lit',
    displayName: 'Zainab Hussain',
    bio: 'Literature student. I annotate everything.',
    stats: [18, 9, 33, 10],
    reviews: [
      ['frankenstein', 4, 'The framing narrative is so clever — letters inside a story inside a story.'],
      ['alice', 5, 'Every chapter is a little logic puzzle. Carroll was having the time of his life.'],
      ['pride', 5, 'The proposal scene at Hunsford is a masterclass in tension.'],
      ['janeeyre', 5, 'Jane’s voice is so modern. “Reader, I married him” earns every word.'],
    ],
    shelf: [
      ['alice', 'finished', 100, 9], ['pride', 'finished', 100, 35], ['janeeyre', 'finished', 100, 70],
      ['frankenstein', 'currentlyReading', 36, 2], ['emma', 'wantToRead', 0, 10],
    ],
    quotes: [
      ['janeeyre', 'I am no bird; and no net ensnares me: I am a free human being with an independent will.', 'Underlined twice in my copy.', 'Chapter 23'],
      ['alice', 'Who in the world am I? Ah, that’s the great puzzle!', 'Me during exam season.', 'Chapter 2', 'friends'],
    ],
    badges: ['avid_reader', 'weekly_reader', 'first_chapter', 'book_starter', 'bookworm', 'highlight_collector'],
    postBadges: 1,
  },
  {
    username: 'omar_novels',
    displayName: 'Omar Farooq',
    bio: 'Audiobooks on the road, paperbacks at home.',
    stats: [12, 5, 19, 8],
    reviews: [
      ['dracula', 3, 'Great opening in Transylvania. The rest drags a bit for me.'],
      ['gatsby', 5, 'Short, sharp and sad. Read it in one sitting.'],
      ['mobydick', 2, ''],
    ],
    shelf: [
      ['gatsby', 'finished', 100, 6], ['dracula', 'finished', 100, 45], ['mobydick', 'currentlyReading', 18, 3],
      ['dorian', 'wantToRead', 0, 9],
    ],
    quotes: [
      ['gatsby', 'So we beat on, boats against the current, borne back ceaselessly into the past.', 'Still thinking about this one days later.', 'Chapter 9'],
      ['mobydick', 'Call me Ishmael.', 'Three words in and I’m hooked. Two hundred pages in and I’m drowning in whale facts.', 'Chapter 1'],
    ],
    badges: ['bookworm', 'first_chapter', 'book_starter', 'steady_reader'],
    postBadges: 1,
  },
  {
    username: 'fatima_tales',
    displayName: 'Fatima Noor',
    bio: 'Fairy tales, folklore and anything with a map in the front.',
    stats: [7, 14, 14, 9],
    reviews: [
      ['alice', 5, 'Read this to my niece and we were both giggling at the Mad Hatter.'],
      ['frankenstein', 4, 'Darker and more thoughtful than I expected.'],
      ['littlewomen', 4, ''],
    ],
    shelf: [
      ['alice', 'finished', 100, 18], ['frankenstein', 'finished', 100, 50], ['littlewomen', 'currentlyReading', 63, 1],
      ['timemachine', 'wantToRead', 0, 20],
    ],
    quotes: [
      ['alice', 'It’s no use going back to yesterday, because I was a different person then.', '', 'Chapter 10'],
    ],
    badges: ['dedicated_reader', 'first_chapter', 'reading_spark', 'weekly_reader'],
    postBadges: 1,
  },
  {
    username: 'usman_chapters',
    displayName: 'Usman Ali',
    bio: 'Detective stories and history. Night owl reader.',
    stats: [15, 2, 21, 9],
    reviews: [
      ['sherlock', 4, 'Holmes’s deductions never get old, even when you can see them coming.'],
      ['dracula', 4, 'Van Helsing is an absolute legend.'],
      ['twocities', 5, 'The last chapter. That’s the review.'],
    ],
    shelf: [
      ['dracula', 'finished', 100, 7], ['twocities', 'finished', 100, 28], ['sherlock', 'currentlyReading', 81, 0],
      ['timemachine', 'wantToRead', 0, 11],
    ],
    quotes: [
      ['dracula', 'Listen to them, the children of the night. What music they make!', 'Read this at 2am. Regret nothing.', 'Chapter 2'],
      ['twocities', 'It was the best of times, it was the worst of times,', '', 'Chapter 1'],
    ],
    badges: ['bookworm', 'avid_reader', 'first_chapter', 'book_starter', 'finisher'],
    postBadges: 0,
  },
  {
    username: 'mariam_reads',
    displayName: 'Mariam Siddiqui',
    bio: 'Book club organiser. Ask me for recommendations!',
    stats: [26, 6, 30, 12],
    reviews: [
      ['pride', 5, 'Our book club’s favourite pick of the year. Everyone had a different favourite Bennet sister.'],
      ['gatsby', 4, 'Sparked the best discussion we have had in months.'],
      ['littlewomen', 5, 'Jo March forever. Bring tissues for the second half.'],
    ],
    shelf: [
      ['pride', 'finished', 100, 16], ['gatsby', 'finished', 100, 30], ['littlewomen', 'finished', 100, 80],
      ['emma', 'currentlyReading', 47, 2], ['twocities', 'wantToRead', 0, 4], ['wuthering', 'wantToRead', 0, 40],
    ],
    quotes: [
      ['gatsby', 'I hope she’ll be a fool — that’s the best thing a girl can be in this world, a beautiful little fool.', 'This line started a forty-minute debate at book club.', 'Chapter 1'],
    ],
    badges: ['library_legend', 'avid_reader', 'first_chapter', 'book_starter', 'bookworm', 'reading_habit'],
    postBadges: 1,
  },
  {
    username: 'ali_bookshelf',
    displayName: 'Ali Raza',
    bio: 'New to reading for fun. Recommendations welcome.',
    stats: [2, 4, 4, 3],
    reviews: [
      ['alice', 4, 'Weird in the best way. Didn’t expect a kids’ book to be this clever.'],
    ],
    shelf: [
      ['alice', 'finished', 100, 3], ['sherlock', 'currentlyReading', 12, 0], ['gatsby', 'wantToRead', 0, 1],
      ['pride', 'wantToRead', 0, 1],
    ],
    quotes: [],
    badges: ['first_chapter', 'first_session', 'reading_spark'],
    postBadges: 1,
  },
];

// Friendships among the sample readers (so their profiles feel lived in).
export const FRIENDSHIPS = [
  ['ayesha_reads', 'sara_bookworm'],
  ['ayesha_reads', 'mariam_reads'],
  ['bilal_pages', 'usman_chapters'],
  ['zainab_lit', 'fatima_tales'],
  ['omar_novels', 'hamza_reader'],
  ['mariam_reads', 'zainab_lit'],
  ['zainab_lit', 'ali_bookshelf'],
  ['sara_bookworm', 'zainab_lit'],
];

// Conversations on sample posts. `on` names a post as
// "username:kind:bookId" (kind: started, finished, shelved, progress,
// review, rating, quote, badge; for badges bookId is the badge id).
// Replies answer the top-level comment.
export const COMMENTS = [
  {
    on: 'ayesha_reads:finished:pride',
    by: 'sara_bookworm',
    text: 'The Hunsford proposal is still the best scene ever written.',
    replies: [
      ['ayesha_reads', 'Agreed! And Darcy’s letter right after it.'],
      ['mariam_reads', 'Book club voted it best chapter, for the record.'],
    ],
  },
  {
    on: 'bilal_pages:finished:sherlock',
    by: 'usman_chapters',
    text: 'Have you tried The Hound of the Baskervilles next?',
    replies: [['bilal_pages', 'On my list for next month!']],
  },
  {
    on: 'sara_bookworm:quote:frankenstein',
    by: 'zainab_lit',
    text: 'This line hits different after the De Lacey chapters.',
    replies: [['sara_bookworm', 'Right? You can feel him breaking.']],
  },
  {
    on: 'omar_novels:review:gatsby',
    by: 'hamza_reader',
    text: 'Five stars?! I gave it three 😅',
    replies: [['omar_novels', 'The ending carries it for me.']],
  },
  { on: 'zainab_lit:review:alice', by: 'fatima_tales', text: 'Carroll’s wordplay is unmatched.', replies: [] },
  {
    on: 'mariam_reads:finished:gatsby',
    by: 'ayesha_reads',
    text: 'What did the book club think of Daisy?',
    replies: [['mariam_reads', 'Very divided. Two people pretended to walk out.']],
  },
  { on: 'fatima_tales:badge:dedicated_reader', by: 'zainab_lit', text: 'Congrats! 🎉', replies: [] },
  {
    on: 'ali_bookshelf:finished:alice',
    by: 'zainab_lit',
    text: 'Welcome to the club! The tea party chapter is my favourite.',
    replies: [['ali_bookshelf', 'Same! What should I read next?'], ['zainab_lit', 'Sherlock Holmes. Short stories, easy wins.']],
  },
  { on: 'hamza_reader:progress:timemachine', by: 'omar_novels', text: 'Halfway already? You’re on a roll.', replies: [] },
  { on: 'usman_chapters:finished:dracula', by: 'bilal_pages', text: 'Van Helsing for president.', replies: [['usman_chapters', 'He has my vote.']] },
  {
    on: 'omar_novels:quote:mobydick',
    by: 'sara_bookworm',
    text: 'The whale facts are the point! …I think.',
    replies: [['omar_novels', 'Chapter 32 has tested my faith.']],
  },
];

// With --friend: these become the tester's friends (when tester credentials
// are given) or send them requests (otherwise).
export const TESTER_FRIENDS = ['ayesha_reads', 'bilal_pages', 'sara_bookworm', 'zainab_lit', 'mariam_reads'];
// These always leave a pending request so the Requests tab has something.
export const TESTER_REQUESTS = ['hamza_reader', 'fatima_tales'];

// With --friend: sample friends talk to the tester. "@tester" is replaced
// with the tester's username.
export const TESTER_MENTIONS = [
  ['ayesha_reads', 'ayesha_reads:quote:pride', '@tester you have to read this one next!'],
  ['sara_bookworm', 'sara_bookworm:quote:dorian', '@tester this is the book I was telling you about.'],
  ['mariam_reads', 'mariam_reads:finished:gatsby', '@tester join our book club next month? We are doing Emma.'],
];
// Comments left on the tester's own (public) posts.
export const TESTER_POST_COMMENTS = [
  ['zainab_lit', 'Ooh, adding this to my list.'],
  ['bilal_pages', 'Great pick!'],
];
