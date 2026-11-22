import 'package:material_ui/material_ui.dart';

/// Format toggle: QR-style grid vs bar-grid barcode. Default is grid.
///
/// Both render the same frames — the toggle only changes how the payload
/// is drawn on the page (2D modules vs tall thin bars).
class FormatToggle extends StatelessWidget {
  /// Creates a format toggle for the current [barcode] mode.
  const FormatToggle({
    required this.barcode,
    required this.onChanged,
    super.key,
  });

  /// True for the bar-grid barcode, false for the 2D grid.
  final bool barcode;

  /// Called when the format changes.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Code format', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(Icons.grid_view),
              label: Text('QR grid'),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(Icons.view_column),
              label: Text('Barcode'),
            ),
          ],
          selected: {barcode},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
        const SizedBox(height: 6),
        Text(
          barcode
              ? 'Tall thin bars, full-bleed — same frames, same decode.'
              : 'One big 2D code per page, logo tile in the centre.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
