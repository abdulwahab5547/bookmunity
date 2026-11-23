# Decisions

## Metadata refresh

EPUB metadata is extracted from the package manifest and spine rather than
assuming common folder names. Refresh updates only title, author, cover, and
the derived book identity key; reading state, shelves, highlights, and notes
remain untouched.

## Reader theme scope

Reader theme controls are intentionally scoped to the reader. The library,
settings, statistics, friends, and account surfaces keep the light
neo-brutalist application theme.

## Cloud sync

The local Drift database stays the working store so the app is instant and
works offline; a sync service mirrors it to Firestore in both directions.
Merges use the edit time (`updatedAt`, newest wins per document) rather than
server time, so an offline edit keeps its real place in history; rules stop
a stale device from moving it backwards. Each account gets its own database
file instead of a `uid` column, so no query can ever leak another account's
rows. Book files are not uploaded: they can be large and may be
copyrighted, so a restored book shows "Not on this device" with a
"Download again" (Discover books) or "Import file" action. Details in
`docs/cloud-data.md`.

