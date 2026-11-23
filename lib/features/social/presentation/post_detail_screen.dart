import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../data/community_models.dart';
import '../data/community_providers.dart';
import '../data/social_models.dart';
import '../data/social_providers.dart';
import 'community_widgets.dart';
import 'user_avatar.dart';

/// A post with its comments and replies, and a box to add one.
class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({
    required this.postId,
    this.initial,
    this.compose = false,
    super.key,
  });

  final String postId;

  /// Shown while the live post loads.
  final Post? initial;

  /// Focus the comment box on open.
  final bool compose;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  PostComment? _replyTo;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    if (widget.compose) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _snack(String text) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _send(Profile me) async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(communityRepositoryProvider)!
          .addComment(widget.postId, text, me, parentId: _replyTo?.id ?? '');
      _text.clear();
      setState(() => _replyTo = null);
    } catch (error) {
      if (mounted) _snack(socialErrorMessage(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _reply(PostComment comment) {
    setState(() => _replyTo = comment);
    _focus.requestFocus();
  }

  Future<void> _delete(PostComment comment, List<PostComment> replies) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this comment?'),
        content: replies.isEmpty
            ? null
            : Text(
                'Its ${replies.length} '
                '${replies.length == 1 ? 'reply is' : 'replies are'} '
                'deleted too.',
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: BrutalColors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(communityRepositoryProvider)!
          .deleteComment(widget.postId, comment, replies: replies);
      if (_replyTo?.id == comment.id) setState(() => _replyTo = null);
    } catch (error) {
      if (mounted) _snack(socialErrorMessage(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(postProvider(widget.postId));
    final post = live.valueOrNull ?? widget.initial;
    final me = ref.watch(myProfileProvider).valueOrNull;
    final theme = Theme.of(context);

    if (live.hasValue && live.value == null) {
      return const Scaffold(
        appBar: BrutalAppBar(title: 'Post'),
        body: EmptyState(
          icon: Icons.delete_outline,
          title: 'This post was deleted',
        ),
      );
    }
    if (post == null) {
      return Scaffold(
        appBar: const BrutalAppBar(title: 'Post'),
        body: live.hasError
            ? EmptyState(
                icon: Icons.cloud_off_outlined,
                title: 'Post unavailable',
                message: socialErrorMessage(live.error!),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }

    final comments = ref.watch(commentsProvider(widget.postId));
    return Scaffold(
      appBar: const BrutalAppBar(title: 'Post'),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [
                PostCard(post: post, expanded: true),
                const SizedBox(height: 20),
                SectionLabel(
                  post.commentCount == 0
                      ? 'Comments'
                      : 'Comments (${post.commentCount})',
                ),
                comments.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (error, _) => Text(
                    socialErrorMessage(error),
                    style: theme.textTheme.bodySmall,
                  ),
                  data: (items) {
                    final threads = CommentThread.group(items);
                    if (threads.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No comments yet. Start the conversation.',
                          style: theme.textTheme.bodySmall,
                        ),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final thread in threads) ...[
                          CommentTile(
                            comment: thread.comment,
                            canDelete: _canDelete(post, thread.comment, null),
                            onReply: me == null
                                ? null
                                : () => _reply(thread.comment),
                            onDelete: () =>
                                _delete(thread.comment, thread.replies),
                          ),
                          for (final reply in thread.replies)
                            Padding(
                              padding: const EdgeInsets.only(left: 44),
                              child: CommentTile(
                                comment: reply,
                                canDelete: _canDelete(
                                  post,
                                  reply,
                                  thread.comment,
                                ),
                                // Replies to a reply join the same thread.
                                onReply: me == null
                                    ? null
                                    : () => _reply(thread.comment),
                                onDelete: () => _delete(reply, const []),
                              ),
                            ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          if (me != null)
            _Composer(
              controller: _text,
              focusNode: _focus,
              replyTo: _replyTo,
              sending: _sending,
              onCancelReply: () => setState(() => _replyTo = null),
              onSend: () => _send(me),
            ),
        ],
      ),
    );
  }

  /// Mirrors the rules: the comment's author, the post's author, or (for a
  /// reply) the author of the comment it answers.
  bool _canDelete(Post post, PostComment comment, PostComment? parent) {
    final uid = ref.read(communityRepositoryProvider)?.uid;
    if (uid == null) return false;
    if (comment.authorUid == uid || post.authorUid == uid) return true;
    return parent?.authorUid == uid;
  }
}

class CommentTile extends StatelessWidget {
  const CommentTile({
    required this.comment,
    required this.canDelete,
    required this.onReply,
    required this.onDelete,
    super.key,
  });

  final PostComment comment;
  final bool canDelete;
  final VoidCallback? onReply;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = comment.authorDisplayName.isEmpty
        ? '@${comment.authorUsername}'
        : comment.authorDisplayName;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            customBorder: const CircleBorder(),
            onTap: () => openProfile(context, comment.authorUid),
            child: UserAvatar(
              uid: comment.authorUid,
              size: comment.isReply ? 28 : 34,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BrutalTokens.borderRadius,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(comment.text),
                    ],
                  ),
                ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 8, right: 4),
                      child: Text(
                        timeAgo(comment.createdAt),
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                    if (onReply != null)
                      TextButton(
                        onPressed: onReply,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 36),
                        ),
                        child: const Text('Reply'),
                      ),
                    if (canDelete)
                      TextButton(
                        onPressed: onDelete,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 36),
                          foregroundColor: theme.colorScheme.onSurfaceVariant,
                        ),
                        child: const Text('Delete'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.replyTo,
    required this.sending,
    required this.onCancelReply,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final PostComment? replyTo;
  final bool sending;
  final VoidCallback onCancelReply;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final replyTo = this.replyTo;
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: theme.colorScheme.outline)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (replyTo != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Replying to ${replyTo.authorDisplayName.isEmpty ? '@${replyTo.authorUsername}' : replyTo.authorDisplayName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cancel reply',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: onCancelReply,
                    ),
                  ],
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: CommunityLimits.comment,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: replyTo == null
                            ? 'Write a comment…'
                            : 'Write a reply…',
                        counterText: '',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Send',
                    onPressed: sending ? null : onSend,
                    icon: sending
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send, color: BrutalColors.blue),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
