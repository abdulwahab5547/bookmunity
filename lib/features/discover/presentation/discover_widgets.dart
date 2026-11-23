import 'package:flutter/material.dart';

import '../../../design/book_cover.dart';
import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../data/discover_http.dart';
import '../data/discover_models.dart';
import '../data/discover_providers.dart';

/// A remote cover in the app's cover frame, with the title block while it
/// loads or when there is no image.
class DiscoverCover extends StatelessWidget {
  const DiscoverCover({
    required this.title,
    required this.url,
    this.width,
    this.shadow = true,
    super.key,
  });

  final String title;
  final String? url;
  final double? width;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = BookCover(title: title, coverPath: null, shadow: false);
    final image = url == null
        ? fallback
        : Image.network(
            url!,
            fit: BoxFit.cover,
            headers: const {'User-Agent': DiscoverHttp.userAgent},
            cacheWidth: 400,
            errorBuilder: (_, _, _) => fallback,
            frameBuilder: (context, child, frame, synchronous) =>
                frame == null && !synchronous ? fallback : child,
          );
    return AspectRatio(
      aspectRatio: 2 / 3,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: BookCover.colorFor(title),
          borderRadius: BrutalTokens.smallBorderRadius,
          border: Border.all(
            color: scheme.outline,
            width: BrutalTokens.borderWidth,
          ),
          boxShadow: shadow
              ? [
                  BoxShadow(
                    color: scheme.outline,
                    offset: BrutalTokens.shadowOffset,
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: image,
      ),
    );
  }
}

/// Small label with an icon, e.g. "In library".
class DiscoverTag extends StatelessWidget {
  const DiscoverTag({required this.label, this.icon, this.color, super.key});

  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = color;
    final foreground = background == null ? scheme.onSurface : BrutalColors.ink;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outline, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: foreground),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Grid card: cover, title, author, and what state the book is in.
class DiscoverBookCard extends StatelessWidget {
  const DiscoverBookCard({
    required this.book,
    required this.onTap,
    this.inLibrary = false,
    this.download,
    this.showSource = false,
    super.key,
  });

  final DiscoverBook book;
  final VoidCallback onTap;
  final bool inLibrary;
  final DownloadState? download;
  final bool showSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final download = this.download;
    return Semantics(
      button: true,
      label: '${book.title} by ${book.authorLine}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BrutalTokens.smallBorderRadius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DiscoverCover(title: book.title, url: book.coverUrl),
            const SizedBox(height: 8),
            // The text area takes what is left, so long titles or large
            // text sizes shorten the title instead of overflowing.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    book.authorLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  if (download != null && download.active)
                    BrutalProgressBar(
                      value: download.fraction ?? 0.05,
                      height: 6,
                      color: BrutalColors.blue,
                    )
                  else if (inLibrary || download?.phase == DownloadPhase.done)
                    const DiscoverTag(
                      label: 'In library',
                      icon: Icons.check,
                      color: BrutalColors.green,
                    )
                  else if (showSource)
                    DiscoverTag(label: book.source.shortLabel),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Grid used by listings and their skeletons, two columns at 320 dp.
const discoverGridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 168,
  crossAxisSpacing: 14,
  mainAxisSpacing: 18,
  childAspectRatio: 0.45,
);

/// Placeholder cards while a listing loads.
class DiscoverSkeletonGrid extends StatefulWidget {
  const DiscoverSkeletonGrid({this.count = 6, super.key});

  final int count;

  @override
  State<DiscoverSkeletonGrid> createState() => _DiscoverSkeletonGridState();
}

class _DiscoverSkeletonGridState extends State<DiscoverSkeletonGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    lowerBound: 0.45,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
    return SliverFadeTransition(
      opacity: _pulse,
      sliver: SliverGrid.builder(
        gridDelegate: discoverGridDelegate,
        itemCount: widget.count,
        itemBuilder: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BrutalTokens.smallBorderRadius,
                  border: Border.all(color: scheme.outlineVariant),
                ),
              ),
            ),
            const SizedBox(height: 10),
            bar(0.9, 12),
            const SizedBox(height: 6),
            bar(0.6, 10),
          ],
        ),
      ),
    );
  }
}

/// Error, offline and empty states for a listing.
class DiscoverMessage extends StatelessWidget {
  const DiscoverMessage({required this.error, this.onRetry, super.key});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final offline = error is DiscoverOfflineException;
    return EmptyState(
      icon: offline ? Icons.wifi_off : Icons.cloud_off_outlined,
      title: offline ? 'You are offline' : 'Could not load books',
      message: offline
          ? 'Connect to the internet to browse free books. Your library '
                'still works offline.'
          : describeError(error),
      action: onRetry == null
          ? null
          : BrutalPressable(onPressed: onRetry, child: const Text('Try again')),
    );
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
}
