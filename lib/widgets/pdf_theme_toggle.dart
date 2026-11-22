import 'package:material_ui/material_ui.dart';

/// PDF theme toggle: light or dark code pages. Default is light.
///
/// Both carry the same frames — the toggle only changes how the code
/// pages look: black code on white (light) or white code on black
/// (dark). The cover page stays light in both variants.
class PdfThemeToggle extends StatelessWidget {
  /// Creates a PDF theme toggle for the current [dark] mode.
  const PdfThemeToggle({
    required this.dark,
    required this.onChanged,
    super.key,
  });

  /// True for dark code pages, false for light.
  final bool dark;

  /// Called when the theme changes.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PDF theme', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(Icons.light_mode),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(Icons.dark_mode),
              label: Text('Dark'),
            ),
          ],
          selected: {dark},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
        const SizedBox(height: 6),
        Text(
          dark
              ? 'White code on black pages — same frames, same decode.'
              : 'Black code on white pages — prints anywhere.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
