# Reader bridge

The native reader hosts the bundled `epub.js` and `jszip` files in a WebView.
The WebView receives an EPUB URL from a loopback server and does not receive a
base64 copy of the complete book.

JavaScript sends `{event, payload}` through the `readerEvent` handler:

- `ready`
- `relocated` with `cfi`, `percentage`, `chapterHref`, `chapterTitle`, `page`, and `totalPages`
- `metadata` with `language` (the EPUB's `dc:language`, used to pick the dictionary)
- `selected` with `cfiRange`, `text`, `rect`, and `lang` (a `lang`/`xml:lang` set on the passage below `<html>`, or empty)
- `locationsReady`
- `error`

Flutter sends `{name, args}` to `readerCommand`:

- `display` (`cfi` or `href`)
- `next`
- `prev`
- `setTheme`
- `setFontSize`
- `setLineHeight`
- `setMargins`
