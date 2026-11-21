import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../services/platform_limits.dart';

/// Shows the current mode's per-file limit and, when a picked file exceeds
/// it, the routing advice (which mode can hold the file).
class LimitBanner extends StatelessWidget {
  /// Creates a limit banner for [mode], optionally checking [fileSize].
  const LimitBanner({
    required this.mode,
    required this.onModeChanged,
    this.fileSize,
    super.key,
  });

  /// The current encode mode.
  final EncodeMode mode;

  /// Called when the user picks a different mode.
  final ValueChanged<EncodeMode> onModeChanged;

  /// Size of the picked file in bytes, if one is picked.
  final int? fileSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overLimit =
        fileSize != null && !PlatformLimitsService.fits(fileSize!, mode);
    final advice = overLimit
        ? PlatformLimitsService.overLimitAdvice(fileSize!, mode)
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.tune, size: 20),
                const SizedBox(width: 8),
                Text('Encode mode', style: theme.textTheme.titleMedium),
                const Spacer(),
                DropdownButton<EncodeMode>(
                  value: mode,
                  items: [
                    for (final m in PlatformLimitsService.availableModes())
                      DropdownMenuItem(value: m, child: Text(m.label)),
                  ],
                  onChanged: (next) {
                    if (next != null) onModeChanged(next);
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(mode.description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              'Limit: ${formatBytes(mode.maxBytes)} per file',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (advice != null) ...[
              const SizedBox(height: 8),
              Text(
                advice,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
