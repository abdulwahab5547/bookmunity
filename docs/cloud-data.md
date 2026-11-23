# Cloud data layout (Firestore)

Everything about a reader lives in Firestore so it survives a reinstall.
Only EPUB files (and their cover images) stay on the device. A book whose
file is missing locally is still listed, marked "not on this device", and
can be downloaded again from `sourceUrl` or re-imported.

All documents carry `updatedAt` (server timestamp). Clients merge by
"newest `updatedAt` wins" per document. Deletions are soft (`deleted: true`)
for synced collections, so other devices learn about them.

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

| Path | Read | Write | Fields |
|---|---|---|---|
| `users/{uid}/library/{bookKey}` | signed in (public bookshelf) | owner | bookKey, title, author, genre?, shelf (`wantToRead` / `currentlyReading` / `finished`), progress (0–100, same as `Books.progressPercent`), addedAt, startedAt?, finishedAt?, lastOpenedAt?, sourceUrl?, coverUrl? (remote cover if known), deleted (bool), updatedAt |
| `users/{uid}/readingState/{bookKey}` | owner | owner | lastCfi, totalLocations, locationsJson?, updatedAt |
| `users/{uid}/highlights/{highlightId}` | owner | owner | bookKey, cfiRange, selectedText, color, note?, chapterTitle?, createdAt, updatedAt, deleted. `highlightId` is a client-generated UUID-like string. |
| `users/{uid}/bookmarks/{bookmarkId}` | owner | owner | bookKey, cfi, label?, percent, createdAt, updatedAt, deleted |
| `users/{uid}/sessions/{sessionId}` | owner | owner | bookKey, startedAt, endedAt, durationSeconds, startPercent, endPercent |
| `users/{uid}/badges/{badgeId}` | signed in | owner | badgeId, unlockedAt |
| `users/{uid}/private/settings` | owner | owner | reader settings, app theme mode, shareActivity, dictionary languages, library layout, … |

`bookKey` is the identity used everywhere (`title-slug|author-slug`, or
ISBN). Firestore document ids cannot contain `/`, so use the key as is
(`|` is allowed) after replacing any `/` with `_`.

## Community (social feature owns these)

The social feature defines `posts/...` (updates, reviews, ratings, quotes)
with reactions and threaded comments. It reads `users/{uid}/library` to
show a reader's bookshelf on their profile; it must not write it from app
code (the seed script may write sample readers' libraries). Ratings live
with reviews (`books/{bookKey}/reviews/{uid}`), not in the library doc.
