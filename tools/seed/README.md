# Sample readers for Bookmunity

`seed.mjs` creates 10 sample readers with cute avatars, bios, reading stats,
public bookshelves (with Project Gutenberg covers), badges, friendships among
themselves, book reviews and ratings, and about 100 Community posts of every
kind (started, finished, want to read, halfway, reviews, ratings, quotes,
badges) with ~300 reactions and threaded comments, so the Community tab,
reader profiles and book pages have something to show while testing.

It uses the normal Firebase client SDK (no admin key): each sample reader is a
real Email/Password account, and every write goes through `firestore.rules`
exactly like the app's own writes.

## One-time Firebase setup (project owner)

1. **Create the database**: Firebase console → *Firestore Database* → *Create
   database* → **Standard edition**, database ID `(default)`, a location near
   your readers (cannot be changed later), start in **production mode**.
2. **Deploy rules and indexes** from the repo root, logged in with an account
   that owns the `bookmunity` project:

   ```bash
   firebase login            # if needed
   firebase deploy --only firestore --project bookmunity
   ```

3. Make sure *Authentication → Sign-in method → Email/Password* is enabled
   (the app already uses it).

## Seed

```bash
cd tools/seed
npm install

# Sample readers only
node seed.mjs seed

# …and connect them to your own account (sign up in the app first).
# With your credentials, 5 readers become your friends immediately and
# 2 more send you friend requests:
TESTER_EMAIL=you@example.com TESTER_PASSWORD='your-password' \
  node seed.mjs seed --friend your_username

# Without credentials, all 7 send you friend requests to accept in the app.
node seed.mjs seed --friend your_username

# Sample readers accept any requests you sent them from the app:
node seed.mjs accept --friend your_username
```

With `--friend`, the sample friends also mention you in comments on their
posts, and react to and comment on up to 5 of your public posts (post
something first, e.g. rate a book). With `TESTER_EMAIL`/`TESTER_PASSWORD`
you also react and reply to those mentions.

Re-running is safe: accounts, profiles, friendships, posts, reactions and
comments are reused (fixed ids, never duplicated); profiles, reviews, post
texts, shelves and badges are refreshed.

Shelves and badges (`users/{uid}/library`, `users/{uid}/badges`) use the
sync feature's rules; if those are not deployed yet the script warns and
skips them.

Sample accounts sign in as `<username>@seed.bookmunity.app` with password
`bookmunity-seed` (override with `SEED_PASSWORD`), so you can also log in as
one of them to test the other side of a friend request.

Add `--emulator` to target the local emulators
(`firebase emulators:start --only auth,firestore --project demo-bookmunity`,
needs Java 21+).

## Checking the Community rules

```bash
node seed.mjs seed --emulator
node check-community.mjs --emulator
```

`check-community.mjs` (emulator only) runs feed queries, aggregates,
reactions, comments, replies and deletes through the rules, tries ~20
forgeries that must be denied (fake authors, reacting as someone else,
inflating counters, deleting other people's comments, reading friends-only
posts as a stranger, ...), and finally checks that every readable post's
counters equal its actual reaction and comment documents.

## Books with sample reviews

Reviews attach to a book by title and author, so they appear on the book's
screen once you import these Project Gutenberg EPUBs (download, then import
in the app). Book pages opened from the Community tab or a shelf show them
without importing anything:

| Book | EPUB |
|---|---|
| Pride and Prejudice | https://www.gutenberg.org/ebooks/1342.epub3.images |
| Frankenstein | https://www.gutenberg.org/ebooks/84.epub3.images |
| The Adventures of Sherlock Holmes | https://www.gutenberg.org/ebooks/1661.epub3.images |
| Alice's Adventures in Wonderland | https://www.gutenberg.org/ebooks/11.epub3.images |
| The Great Gatsby | https://www.gutenberg.org/ebooks/64317.epub3.images |
| Dracula | https://www.gutenberg.org/ebooks/345.epub3.images |

## Removing sample data

Sample accounts can be deleted in *Authentication → Users* (filter by
`seed.bookmunity.app`); their profiles, usernames, reviews, `users/{uid}`
data and posts (ids start with their uid) are removed in the Firestore
console.
