/// Reflowable book content produced from a PDF and written as EPUB.
sealed class BookBlock {
  const BookBlock();
}

class HeadingBlock extends BookBlock {
  const HeadingBlock(this.text, {this.level = 1});

  final String text;

  /// 1 to 3, rendered as `h1` to `h3`.
  final int level;

  @override
  String toString() => 'h$level: $text';
}

class ParagraphBlock extends BookBlock {
  const ParagraphBlock(this.text, {this.lines});

  /// The paragraph as flowing text.
  final String text;

  /// Set when the original line breaks matter (verse, addresses, lists);
  /// the paragraph is then rendered line by line.
  final List<String>? lines;

  @override
  String toString() => 'p: $text';
}

/// A whole PDF page rendered as an image, used for pages without text
/// (illustrations, plates, scanned pages).
class PageImageBlock extends BookBlock {
  const PageImageBlock(this.pageNumber);

  final int pageNumber;

  @override
  String toString() => 'image: page $pageNumber';
}

class BookChapter {
  const BookChapter({
    required this.title,
    required this.blocks,
    this.listed = true,
  });

  final String title;
  final List<BookBlock> blocks;

  /// Whether the chapter appears in the table of contents.
  final bool listed;
}
