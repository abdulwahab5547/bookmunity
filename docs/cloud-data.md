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
| `users/{uid}/friends/{otherUid}` | owner | either friend | |
| `users/{uid}/activity/{id}` | owner + friends | owner | legacy friends feed |
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

The social feature defines `posts/...` (updates, reviews, ratings, quotes)
with reactions and threaded comments. It reads `users/{uid}/library` to
show a reader's bookshelf on their profile; it must not write it from app
code (the seed script may write sample readers' libraries). Ratings live
with reviews (`books/{bookKey}/reviews/{uid}`), not in the library doc.
