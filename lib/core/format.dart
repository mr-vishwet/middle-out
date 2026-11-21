/// Human-readable formatting for sizes, ratios and durations used across the
/// Middle Out UI.
library;

/// Formats [bytes] as "14.2 MB", "1.04 GB", "512 B" (one decimal, trimmed).
String formatBytes(int bytes) {
  if (bytes < 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final text = value >= 100
      ? value.toStringAsFixed(0)
      : value >= 10
          ? value.toStringAsFixed(1)
          : value.toStringAsFixed(2);
  final trimmed = text.contains('.')
      ? text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
      : text;
  return '$trimmed ${units[unit]}';
}

/// Formats a compression ratio, e.g. 73.2 -> "73×".
String formatRatio(double ratio) {
  if (ratio.isNaN || ratio.isInfinite) return '—';
  if (ratio >= 100) return '${ratio.toStringAsFixed(0)}×';
  return '${ratio.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')}×';
}

/// Formats a duration in seconds as "40s", "2m 05s", "1h 12m".
String formatDuration(int totalSeconds) {
  if (totalSeconds < 60) return '${totalSeconds}s';
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (minutes < 60) return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  final hours = minutes ~/ 60;
  return '${hours}h ${(minutes % 60).toString().padLeft(2, '0')}m';
}

/// Shortens a hex hash for display: "9f2c41be 7d03a81d …".
String shortHash(String hex, {int groups = 2}) {
  final clean = hex.replaceAll(' ', '');
  final shown = clean.substring(0, (groups * 8).clamp(0, clean.length));
  final parts = <String>[];
  for (var i = 0; i < shown.length; i += 8) {
    parts.add(shown.substring(i, (i + 8).clamp(0, shown.length)));
  }
  return '${parts.join(' ')} …';
}
