import 'package:flutter/material.dart';

/// Format toggle: QR-style grid vs stacked-row barcode. Default is grid.
///
/// Both render the same frames — the toggle only changes how the payload
/// is drawn on the page (2D modules vs 1D bars).
class FormatToggle extends StatelessWidget {
  const FormatToggle({
    required this.barcode,
    required this.onChanged,
    super.key,
  });

  final bool barcode;
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
              ? 'Stacked rows of bars — scans like a barcode, same frames.'
              : 'One big 2D code per page, logo tile in the centre.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
