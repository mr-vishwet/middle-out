import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/adaptive.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../state/app_scope.dart';
import '../state/link_store.dart';

/// Share sheet (m09/w09): the PDF file, or a link that expires in 7 days.
///
/// The PDF share is real (system share sheet). Links are demo records
/// until cloud sharing ships in phase 2 — created, listed with their
/// expiry, and revocable, but labelled DEMO because they do not resolve
/// anywhere yet.
class ShareScreen extends StatelessWidget {
  /// Creates the share screen.
  const ShareScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    final controller = state.encode;
    return AdaptiveScaffold(
      title: 'Share',
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final hasPdf =
              controller.pdfBytes != null && controller.file != null;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!hasPdf)
                  const EmptyState(
                    icon: Icons.ios_share,
                    headline: 'Nothing to share yet',
                    body: 'Encode a file and the share sheet — PDF file, '
                        'expiring link, save to Files — shows up here.',
                  )
                else
                  TwoPane(
                    first: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Share the PDF',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${controller.file!.name}.middleout.pdf · '
                              '${formatBytes(controller.pdfBytes!.length)}',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: controller.shareResultPdf,
                              icon: const Icon(Icons.ios_share),
                              label: const Text('Share PDF file'),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: controller.saveResultPdf,
                              icon: const Icon(Icons.save),
                              label: const Text('Save to Files'),
                            ),
                            if (controller.savedPath != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Saved: ${controller.savedPath}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                            if (controller.error != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                controller.error!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    second: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Expanded(
                                  child: Text('Share a link'),
                                ),
                                DemoChip(),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'A link that expires in 7 days. Demo for now: '
                              'the link is created and listed here, but it '
                              'resolves only once cloud sharing ships in '
                              'phase 2. The PDF file above is what you '
                              'share today.',
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: () async {
                                final link = await state.links.create(
                                  controller.file!.name,
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: const Text(
                                        'Demo link created — expires in 7 days',
                                      ),
                                      action: SnackBarAction(
                                        label: 'Copy',
                                        onPressed: () {
                                          Clipboard.setData(
                                            ClipboardData(text: link.url),
                                          );
                                        },
                                      ),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.link),
                              label: const Text('Create expiring link'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                ListenableBuilder(
                  listenable: state.links,
                  builder: (context, _) {
                    if (state.links.links.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return _LinksCard(state: state);
                  },
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.payoff,
                  ),
                  child: const Text('Share the story instead'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Created links, with expiry and revoke.
class _LinksCard extends StatelessWidget {
  /// Creates a links card.
  const _LinksCard({required this.state});

  /// App state.
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Your links', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                const DemoChip(),
              ],
            ),
            const SizedBox(height: 8),
            for (final link in state.links.links)
              _LinkRow(link: link, state: state),
          ],
        ),
      ),
    );
  }
}

/// One link row: URL, file, expiry, copy + revoke.
class _LinkRow extends StatelessWidget {
  /// Creates a link row.
  const _LinkRow({required this.link, required this.state});

  /// The link.
  final SharedLink link;

  /// App state.
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final status = link.revoked
        ? 'Revoked'
        : link.expired
            ? 'Expired'
            : 'Expires ${link.expiresAt.day}/${link.expiresAt.month}/${link.expiresAt.year}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(link.url, overflow: TextOverflow.ellipsis),
      subtitle: Text('${link.fileName} · $status'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy link',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link.url));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link copied')),
              );
            },
          ),
          if (link.isLive)
            IconButton(
              icon: const Icon(Icons.block),
              tooltip: 'Revoke link',
              onPressed: () => state.links.revoke(link.id),
            ),
        ],
      ),
    );
  }
}
