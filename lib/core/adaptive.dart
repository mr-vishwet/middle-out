import 'package:flutter/material.dart';

/// Adaptive layout helpers: one codebase, two layouts.
///
/// Below [Adaptive.wideBreakpoint] the mobile layout renders (single
/// column, bottom navigation); at and above it the web layout renders
/// (centred content column, side-by-side panes, navigation rail). Every
/// screen uses these helpers so the 30 routes cover both the m01–m30 and
/// w01–w30 V7 screens.
abstract final class Adaptive {
  /// Logical-width breakpoint between the mobile and web layouts.
  static const double wideBreakpoint = 800;

  /// Maximum content width on the web layout.
  static const double maxContentWidth = 960;

  /// True when the web layout should render.
  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= wideBreakpoint;
}

/// A [Scaffold] whose body is centred and width-capped on wide screens.
///
/// Screens pass their (usually scrolling) body; on mobile it fills the
/// width, on web it sits in a centred column up to
/// [Adaptive.maxContentWidth] wide.
class AdaptiveScaffold extends StatelessWidget {
  /// Creates an adaptive scaffold with a title and a body.
  const AdaptiveScaffold({
    required this.title,
    required this.body,
    this.actions,
    this.floatingActionButton,
    this.showBack = true,
    super.key,
  });

  /// App bar title.
  final String title;

  /// Screen body.
  final Widget body;

  /// App bar actions.
  final List<Widget>? actions;

  /// Optional floating action button.
  final Widget? floatingActionButton;

  /// Whether the AppBar shows an automatic back button.
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final wide = Adaptive.isWide(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: actions,
        automaticallyImplyLeading: showBack,
      ),
      floatingActionButton: floatingActionButton,
      body: wide
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: Adaptive.maxContentWidth,
                ),
                child: body,
              ),
            )
          : body,
    );
  }
}

/// Two panes: stacked vertically on mobile, side by side on web.
///
/// Used by screens whose web layout is a two-column arrangement (the w*
/// V7 screens) while the mobile layout is a single scrolling column.
class TwoPane extends StatelessWidget {
  /// Creates a two-pane layout from [first] and [second].
  const TwoPane({
    required this.first,
    required this.second,
    this.firstFlex = 1,
    this.secondFlex = 1,
    this.spacing = 16,
    super.key,
  });

  /// The leading pane (top on mobile, left on web).
  final Widget first;

  /// The trailing pane (bottom on mobile, right on web).
  final Widget second;

  /// Flex of the leading pane on web.
  final int firstFlex;

  /// Flex of the trailing pane on web.
  final int secondFlex;

  /// Gap between the panes.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (!Adaptive.isWide(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          first,
          SizedBox(height: spacing),
          second,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: firstFlex, child: first),
        SizedBox(width: spacing),
        Expanded(flex: secondFlex, child: second),
      ],
    );
  }
}

/// Small "DEMO" badge marking seeded example content.
///
/// Demo records and demo numbers are never presented as measurements;
/// wherever they appear they carry this chip (see README "Honest limits").
class DemoChip extends StatelessWidget {
  /// Creates a DEMO badge.
  const DemoChip({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'DEMO',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onPrimary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Shared empty-state: an icon, a headline, an explanation, one action.
class EmptyState extends StatelessWidget {
  /// Creates an empty state with an [icon], [headline] and [body].
  const EmptyState({
    required this.icon,
    required this.headline,
    required this.body,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  /// Icon shown above the headline.
  final IconData icon;

  /// Headline text.
  final String headline;

  /// Explanatory text.
  final String body;

  /// Optional action button label.
  final String? actionLabel;

  /// Optional action button callback.
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(headline, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              body,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
