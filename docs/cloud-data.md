# Cloud data layout (Firestore)

Everything about a reader lives in Firestore so it survives a reinstall.
Only EPUB files (and their cover images) stay on the device. A book whose
file is missing locally is still listed, marked "not on this device", and
can be downloaded again from `sourceUrl` or re-imported.

All documents carry `updatedAt`. Clients merge by "newest `updatedAt` wins"
per document. Deletions are soft (`deleted: true`) for synced collections,
so other devices learn about them. The synced personal collections use the
edit time for `updatedAt` plus a server-time `syncedAt`; see "Timestamps
and merging" below.

## Existing (do not change shape without updating every reader of it)

| Path | Read | Write | Notes |
|---|---|---|---|
| `profiles/{uid}` | signed in | owner | username, displayName, bio, hasPhoto, stats summary (booksFinished, currentStreak, longestStreak, badgeCount) |
| `usernames/{name}` | anyone (get) | owner (create) | username → uid |
| `avatars/{uid}` | signed in | owner | base64 JPEG |
| `friendRequests/{from_to}` | the two users | sender / recipient | |
| `users/{uid}/friends/{otherUid}` | signed in (public friend list, counted on profiles) | either friend | |
| `users/{uid}/activity/{id}` | owner + friends | owner | legacy friends feed: no longer written or shown by the app (replaced by `posts`); kept readable for older app versions |
| `books/{bookKey}/reviews/{uid}` | signed in | owner | one review per reader per book |

## Personal library (sync feature owns writing these)

Written only by the sync service in `lib/core/sync/`. Rules: the
"personal library sync" block in `firestore.rules`.

| Path | Read | Write | Fields |
|---|---|---|---|
| `users/{uid}/library/{bookDocId}` | signed in (public bookshelf) | owner | bookKey, title, author, genre?, shelf (`wantToRead` / `currentlyReading` / `finished`), progress (0–100, same as `Books.progressPercent`), addedAt, finishedAt?, lastOpenedAt?, sourceUrl?, fileHash? (SHA-256 of the EPUB), coverUrl? (reserved, not written yet), deleted (bool), updatedAt, syncedAt |
| `users/{uid}/readingState/{bookDocId}` | owner | owner | bookKey, lastCfi?, totalLocations?, updatedAt, syncedAt |
| `users/{uid}/highlights/{remoteId}` | owner | owner | bookKey, cfiRange, selectedText (≤ 10000), color, note? (≤ 10000), chapterTitle?, createdAt, updatedAt, deleted, syncedAt |
| `users/{uid}/bookmarks/{remoteId}` | owner | owner | bookKey, cfi, label?, percent, createdAt, updatedAt, deleted, syncedAt |
| `users/{uid}/sessions/{remoteId}` | owner | owner | bookKey, startedAt, endedAt, durationSeconds, startPercent, endPercent, updatedAt, syncedAt |
| `users/{uid}/badges/{badgeId}` | signed in | owner | badgeId, unlockedAt, updatedAt, syncedAt |
| `users/{uid}/private/settings` | owner | owner | values (map), stamps (map key → timestamp), updatedAt, syncedAt |

Readers of `library` (profiles, bookshelf) must skip `deleted == true`.

### Ids

- `bookDocId` is the `bookKey` with `/` replaced by `_` (and prefixed with
  `k_` in the rare case it is empty, `.`, `..` or `__x__`). See
  `bookDocId()` in `lib/core/sync/remote_store.dart`. Books that never had
  a key get `file-<first 16 hex of the file hash>` during the v6 migration.
- `remoteId` (highlights, bookmarks, sessions) is a random 128-bit hex
  string generated on the device and stored in the local `remoteId`
  column. Existing rows got one in the v6 migration.

### Timestamps and merging

- `updatedAt` is the time of the **edit**, from the editing device's clock
  (the local `changedAt` column, in ms). It is the merge clock: per
  document, the newer `updatedAt` wins; an equal one is an echo and is
  ignored. Rules reject an update that moves `updatedAt` backwards (so a
  stale device cannot overwrite a newer edit) and any value more than one
  hour ahead of server time.
- `syncedAt` is `FieldValue.serverTimestamp()` on every write. Clients
  listen with `where('syncedAt', '>=', lastSeen)` per collection, so a
  restart only downloads what changed. The watermark is kept in the local
  `sync_meta` table.
- A book row has two clocks: `changedAt` for library fields and
  `stateChangedAt` for the reading position, matching the two documents.
- Sessions are immutable and badges permanent: they are unioned, and a
  badge keeps its earliest `unlockedAt` on every device.
- Settings merge **per key** using `stamps`; writes use `merge: true`, so
  features can add keys without knowing about each other.
- `locationsJson` (epub.js locations) is a regenerable cache and stays on
  the device.

### Deletes

Soft tombstones: the document is rewritten with `deleted: true` (library
entries keep their other fields). Locally the row is hidden at once, pushed,
then purged. Deleting a book tombstones its highlights and bookmarks too;
its sessions and badges stay. When a metadata refresh changes a book's key,
the old library document is tombstoned (a merge write of `bookKey`,
`deleted`, `updatedAt`) and the book's highlights, bookmarks and sessions
are re-pushed under the new key.

### Push and pull

- Local Drift is the working store; the app never waits for the network.
  Each synced row has `dirty` (not yet handed to Firestore).
- Pushes are batched (up to 400 writes per batch). If a batch is rejected,
  its writes are retried one by one so one bad document does not block the
  rest; failures stay dirty and retry with backoff (30 s up to 15 min).
- Reading-position saves only dirty the book row and are pushed at most
  every 20 s. Other changes go out after 2 s. Everything pending is flushed
  when the app goes to the background and before sign-out.
- A commit still pending after 10 s is treated as queued by Firestore's
  offline persistence; the rows are marked clean and marked dirty again if
  the server later rejects it.
- Nothing is pushed until every collection has answered from the server
  once (or 15 s have passed), so a fresh device merges the cloud first.
- Highlights, bookmarks and reading state that arrive before their library
  entry wait in memory and are applied when it arrives.

### Files and "Not on this device"

Only EPUBs and covers stay local, stored by hash (`books/<hash>.epub`,
`covers/<hash>.jpg`). A restored book has `filePath == null` and shows
"Not on this device" on its library tile and book screen:

- `sourceUrl` set: "Download again" fetches it and attaches it.
- Otherwise: "Import file" re-attaches the reader's own EPUB.

Importing a book whose row exists without a file (same hash, else same
`bookKey`) attaches the file to that row instead of adding a duplicate, so
progress, highlights and notes are kept. On every database open, paths are
healed: a file already on disk with the row's `fileHash` (another account
on the same device, an iOS container move) is attached, and a path whose
file is gone is cleared.

### Accounts

Each account has its own database file, `bookmunity_<uid>.sqlite`
(IndexedDB `bookmunity_<uid>` on web), and its own settings cache
(`cloud_settings.<uid>` in SharedPreferences), so nothing leaks between
accounts. Signed-out/offline use (no Firebase) keeps `bookmunity.sqlite`
with no sync. Book files are shared by hash; library rows never are.

### Upgrading existing installs

- Schema v6 marks every existing row dirty, so the first signed-in launch
  uploads the whole local library, its highlights, sessions and badges.
- The first account to sign in on this version adopts the old shared
  `bookmunity.sqlite` (renamed to that account's file). Other accounts
  start from their cloud copy.
- The old SharedPreferences settings (`reader_*`, `app_theme_mode`,
  `share_activity`, `library_grid`) are imported once per device with the
  oldest possible stamp, so any value already in the cloud wins.

## Community (social feature owns these)

Rules: the `COMMUNITY` block at the end of `firestore.rules`. Code:
`lib/features/social/data/community_*.dart`. The feature reads
`users/{uid}/library` and `users/{uid}/badges` for profiles (skipping
`deleted` entries) but never writes them; only the seed script does, for
sample readers. Ratings live with reviews (`books/{bookKey}/reviews/{uid}`),
not in the library doc.

| Path | Read | Write | Fields |
|---|---|---|---|
| `posts/{postId}` | signed in: `public` posts; `friends` posts by the author and their friends | author creates/edits/deletes; anyone may change counters only together with their own reaction or a comment | authorUid, authorUsername, authorDisplayName (== profile), type, visibility, bookKey, title, author, coverUrl, rating, text, quote, chapter, progress, badgeId, badgeTitle, reactions {like, love, haha, wow, sad}, commentCount, commentOpId, createdAt, updatedAt |
| `posts/{postId}/reactions/{uid}` | whoever can read the post | that reader | uid, type, username, displayName, updatedAt |
| `posts/{postId}/comments/{id}` | whoever can read the post | create: any reader of the post; delete: comment author, post author, or (replies) the thread's author | authorUid, authorUsername, authorDisplayName, text (1–1000), parentId ('' or a top-level comment id), createdAt |

### Post types

| type | Made when | Content |
|---|---|---|
| `started` | shelf → Currently reading, or a book is first opened | book |
| `finished` | the reader reaches the end, or shelf → Read | book |
| `shelved` | shelf → Want to read | book |
| `progress` | reading passes 50% | book, progress = 50 |
| `review` / `rating` | a review is saved (`rating` when there is no text); re-saving updates the same post, deleting the review deletes it | book, rating 1–5, text |
| `quote` | "Share as quote" on a highlight (reader sheet or highlights list) | book, quote (≤ 1000), text = note, chapter, visibility chosen by the reader |
| `badge` | a badge unlocks (at most 3 at once) | badgeId, badgeTitle |

Ids start with the author's uid (the rules enforce it): `{uid}_review_{book}`,
`{uid}_{started|finished|shelved|progress}_{book}`, `{uid}_badge_{badgeId}`
are deterministic, so each exists once and saving again never duplicates
them; quotes use `{uid}_{autoId}`. `{book}` is the bookKey with `/` → `-`
(`reviewDocKey`), the same key used by `books/{bookKey}`.

Automatic posts (all but quotes) respect the `share_activity` setting; an
existing review post is still kept in sync when it is off, but no new one is
made. Quotes are an explicit action and always post.

### Visibility and feeds

- `visibility` is `public` (Everyone) or `friends`. Automatic posts are
  public; quotes let the reader pick.
- Everyone: `where visibility == 'public' orderBy createdAt desc`.
- Friends: `where authorUid in [me + friends] orderBy createdAt desc`, one
  query per 30 authors (`whereIn` limit), merged newest first client-side
  (`MergedPager`). The rules evaluate each `in` value, so friends-only posts
  are allowed only when every listed author is the reader or a friend.
- A profile lists `authorUid == X` (plus `visibility == 'public'` unless X
  is the reader or a friend). Book pages list public quotes by `bookKey`.
- Pagination is cursor based (`startAfterDocument`), 15 posts per page.

### Counters

`reactions` and `commentCount` are counters on the post so feeds don't need
extra reads, and they cannot be forged:

- Every change goes in one atomic write with the reaction/comment it counts,
  using `FieldValue.increment` (concurrent writers don't lose updates).
- The post rule only lets non-authors touch the counters, and only when the
  reader's reaction doc changed in that same write (`exists` vs
  `existsAfter`), with each reaction type moving by exactly that change; or
  when `commentCount` moves by one and the comment named in `commentOpId` is
  created/deleted in that write.
- The reaction/comment rules require the matching counter change on the post
  (`get` vs `getAfter`). Together neither side can change alone.
- Reactions run in a transaction so the "before" reaction is always current.

Aggregate `count()` / `average()` queries are used where the number belongs
to someone else's data: a book's rating (`books/{key}/reviews`), a reader's
ratings (collection group `reviews` where `uid`), and friend counts.

### Deleting

Comments can't be edited. Deleting a top-level comment deletes its replies
first (one counted write each). Deleting a post deletes the post, then its
comments and reactions; the rules let anyone delete children of a post that
no longer exists, so an interrupted clean-up can be finished later.
