import 'package:material_ui/material_ui.dart';

import '../core/adaptive.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../services/share_service.dart';
import '../state/app_scope.dart';
import '../widgets/app_logo.dart';

/// The payoff (m20/w20): "14 MB? That's the whole film?" — send small,
/// open big.
///
/// Shows the last real encode when there is one, otherwise the seeded
/// demo story, labelled DEMO. The share actions are real: share the PDF,
/// or share the story as text.
class PayoffScreen extends StatelessWidget {
  /// Creates the payoff screen.
  const PayoffScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return AdaptiveScaffold(
      title: 'The payoff',
      body: ListenableBuilder(
        listenable: state.history,
        builder: (context, _) {
          final lastReal = state.history.encodes.isEmpty
              ? null
              : state.history.encodes.first;
          final demo = lastReal == null;
          final headline = demo
              ? '1.04 GB in, 14.2 MB out'
              : '${formatBytes(lastReal.originalBytes)} in, '
                  '${formatBytes(lastReal.encodedBytes)} out';
          final ratio = demo ? '73×' : formatRatio(lastReal.ratio);
          final story = demo
              ? 'Middle Out squeezed a 1.04 GB podcast master into a '
                  '14.2 MB PDF — 73× smaller — and it decodes back '
                  'bit-for-bit. (Demo story.)'
              : 'Middle Out squeezed ${lastReal.fileName} from '
                  '${formatBytes(lastReal.originalBytes)} into '
                  '${formatBytes(lastReal.encodedBytes)} — '
                  '${formatRatio(lastReal.ratio)} smaller — and it '
                  'decodes back bit-for-bit.';
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(
                  child: AppLogo(variant: LogoVariant.appIcon, width: 96),
                ),
                const SizedBox(height: 24),
                Text(
                  '“14 MB? That’s the whole film?”',
                  style: theme.textTheme.displaySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Send small, open big.',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        if (demo) ...[
                          const DemoChip(),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          headline,
                          style: theme.textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$ratio smaller · SHA-256 verified',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => ShareService.shareText(
                    story,
                    subject: 'Middle Out — send small, open big',
                  ),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share the story'),
                ),
                const SizedBox(height: 12),
                ListenableBuilder(
                  listenable: state.encode,
                  builder: (context, _) {
                    final hasPdf = state.encode.pdfBytes != null;
                    return OutlinedButton.icon(
                      onPressed: hasPdf
                          ? state.encode.shareResultPdf
                          : null,
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: Text(
                        hasPdf
                            ? 'Share the latest PDF'
                            : 'No PDF yet — encode a file first',
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context)
                      .pushNamed(AppRoutes.encodePick),
                  child: const Text('Encode a file'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
