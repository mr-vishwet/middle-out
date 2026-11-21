import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/adaptive.dart';
import '../core/format.dart';
import '../core/routes.dart';
import '../services/file_saver.dart' show saveFileBytes;
import '../services/platform_limits.dart';
import '../services/share_service.dart';
import '../state/app_scope.dart';
import '../state/auth_controller.dart';
import '../widgets/app_logo.dart';
import 'shell_screen.dart';

/// Welcome (m21/w21): start as a guest — no account needed. The whole
/// product works guest-first.
class WelcomeScreen extends StatelessWidget {
  /// Creates the welcome screen.
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return AdaptiveScaffold(
      title: 'Welcome',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(
              child: AppLogo(variant: LogoVariant.stacked, width: 220),
            ),
            const SizedBox(height: 24),
            Text(
              'Start as a guest — no account needed.',
              style: theme.textTheme.displaySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Encode, decode, batch and history all work without '
              'signing in. An account adds sync, cloud encode and '
              'shared links.',
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                state.auth.continueAsGuest();
                Navigator.of(context).pushNamed(AppRoutes.authGuest);
              },
              child: const Text('Continue as guest'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pushNamed(
                AppRoutes.authSignIn,
              ),
              child: const Text('Sign in'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(context).pushNamed(
                AppRoutes.authCreate,
              ),
              child: const Text('Create account'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Guest mode, explained (m22/w22): no account, no upload, no sync.
/// The queue stays on this device.
class GuestExplainerScreen extends StatelessWidget {
  /// Creates the guest-mode explainer.
  const GuestExplainerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return AdaptiveScaffold(
      title: 'Guest mode',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'No account, no upload, no sync.',
              style: theme.textTheme.displaySmall,
            ),
            const SizedBox(height: 16),
            const _GuestPoint(
              icon: Icons.person_off_outlined,
              title: 'No account',
              text: 'Nothing to sign up for. The whole product works.',
            ),
            const _GuestPoint(
              icon: Icons.cloud_off_outlined,
              title: 'No upload',
              text: 'Files never leave this device in local mode.',
            ),
            const _GuestPoint(
              icon: Icons.sync_disabled,
              title: 'No sync',
              text: 'The queue and history stay on this device.',
            ),
            const _GuestPoint(
              icon: Icons.move_up,
              title: 'Migrate any time',
              text: 'Create an account later and your guest work moves '
                  'with you, verified item by item.',
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                state.auth.continueAsGuest();
                popToShell(context);
              },
              child: const Text('Keep going as guest'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pushNamed(
                AppRoutes.authSignIn,
              ),
              child: const Text('Sign in instead'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One guest-mode bullet.
class _GuestPoint extends StatelessWidget {
  /// Creates a guest-mode bullet.
  const _GuestPoint({
    required this.icon,
    required this.title,
    required this.text,
  });

  /// Bullet icon.
  final IconData icon;

  /// Bullet title.
  final String title;

  /// Bullet text.
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                Text(text, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Sign in (m23/w23): sync queue + history, cloud encode, shared links.
class SignInScreen extends StatefulWidget {
  /// Creates the sign-in screen.
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    final auth = state.auth;
    return AdaptiveScaffold(
      title: 'Sign in',
      body: ListenableBuilder(
        listenable: auth,
        builder: (context, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Sync queue + history, cloud encode, shared links.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Accounts are stored on this device in phase 1; cloud '
                  'sync arrives with the backend in phase 2.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (auth.needsCreate) ...[
                  const SizedBox(height: 16),
                  Text(
                    'No account with that email on this device.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pushNamed(
                      AppRoutes.authCreate,
                      arguments: _email.text,
                    ),
                    child: const Text('Create account with this email'),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _email.text.trim().isEmpty
                      ? null
                      : () {
                          auth.startSignIn(email: _email.text);
                          if (!auth.needsCreate) {
                            Navigator.of(context).pushNamed(
                              AppRoutes.authVerify,
                            );
                          }
                        },
                  child: const Text('Continue'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pushNamed(
                    AppRoutes.authCreate,
                  ),
                  child: const Text('No account yet? Create one'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Create account (m24/w24): one account, every device — your guest work
/// migrates with you.
class CreateAccountScreen extends StatefulWidget {
  /// Creates the create-account screen, optionally pre-filling [email].
  const CreateAccountScreen({this.email, super.key});

  /// Email to pre-fill (from the sign-in screen's no-account path).
  final String? email;

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  late final TextEditingController _email;
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _email = TextEditingController(text: widget.email ?? '');
  }

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return AdaptiveScaffold(
      title: 'Create account',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'One account, every device.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Your guest work migrates with you, verified item by item.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Display name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _email.text.trim().isEmpty
                  ? null
                  : () {
                      state.auth.startCreateAccount(
                        email: _email.text,
                        displayName: _name.text,
                      );
                      Navigator.of(context).pushNamed(AppRoutes.authVerify);
                    },
              child: const Text('Create account'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Verify (m25/w25): magic link or 6-digit code, works on any device.
///
/// Phase 1 has no email delivery, so the 6-digit code is generated
/// on-device and shown in-app, labelled DEMO. The magic-link button
/// explains that email delivery ships with the backend in phase 2.
class VerifyCodeScreen extends StatefulWidget {
  /// Creates the verification screen.
  const VerifyCodeScreen({super.key});

  @override
  State<VerifyCodeScreen> createState() => _VerifyCodeScreenState();
}

class _VerifyCodeScreenState extends State<VerifyCodeScreen> {
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    final auth = state.auth;
    return AdaptiveScaffold(
      title: 'Verify',
      body: ListenableBuilder(
        listenable: auth,
        builder: (context, _) {
          if (auth.pendingEmail == null || auth.demoCode == null) {
            return EmptyState(
              icon: Icons.mark_email_read_outlined,
              headline: 'Nothing to verify',
              body: 'Sign in or create an account first — the '
                  'verification step follows.',
              actionLabel: 'Sign in',
              onAction: () => Navigator.of(context)
                  .pushReplacementNamed(AppRoutes.authSignIn),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'We would send a code to ${auth.pendingEmail}.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Expanded(
                              child: Text('Your demo code'),
                            ),
                            DemoChip(),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          auth.demoCode!,
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'No email is sent in phase 1 — in production '
                          'this code arrives by email.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    labelText: '6-digit code',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    final ok = await auth.verifyCode(_code.text);
                    if (!context.mounted) return;
                    if (!ok) {
                      setState(() {
                        _error = 'That code does not match — try again, '
                            'or resend a fresh code.';
                      });
                      return;
                    }
                    final guestItems = state.history.real.length +
                        state.batch.queued.length;
                    final needsMigrate = guestItems > 0 &&
                        !(auth.account?.migrated ?? false);
                    if (context.mounted) {
                      Navigator.of(context).pushReplacementNamed(
                        needsMigrate
                            ? AppRoutes.authMigrate
                            : AppRoutes.account,
                      );
                    }
                  },
                  child: const Text('Verify'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: auth.resendCode,
                  child: const Text('Resend code'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Magic link'),
                      content: const Text(
                        'Magic-link email delivery ships with the backend '
                        'in phase 2. Use the demo code above to continue.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('Send a magic link instead'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Upgrade prompt (m26/w26): a file needs cloud encode — the browser
/// limit is 10 GB.
class UpgradePromptScreen extends StatelessWidget {
  /// Creates the upgrade prompt for an optional [fileSize].
  const UpgradePromptScreen({this.fileSize, super.key});

  /// Size of the over-limit file, in bytes.
  final int? fileSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    final size = fileSize;
    return AdaptiveScaffold(
      title: 'Need more room?',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              size == null
                  ? 'This file needs cloud encode.'
                  : 'A ${formatBytes(size)} file needs cloud encode — '
                      'the browser limit is 10 GB.',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TwoPane(
              first: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Limits',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      _limitRow(theme, 'Web · Local', '10 GB'),
                      _limitRow(theme, 'Web · Cloud', '50 GB'),
                      _limitRow(theme, 'Native app', '100 GB'),
                    ],
                  ),
                ),
              ),
              second: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton(
                    onPressed: () {
                      if (state.auth.isSignedIn) {
                        state.encode.setMode(EncodeMode.webCloud);
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Switched to Web · Cloud mode. Cloud upload '
                              'ships in phase 2 — files still encode '
                              'locally in this build.',
                            ),
                          ),
                        );
                      } else {
                        Navigator.of(context)
                            .pushNamed(AppRoutes.authSignIn);
                      }
                    },
                    child: Text(
                      state.auth.isSignedIn
                          ? 'Switch to cloud encode'
                          : 'Sign in for cloud encode',
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Native app'),
                        content: const Text(
                          'The native app encodes up to 100 GB per file, '
                          'streaming and local. Install Middle Out on '
                          'your phone or computer for the biggest files.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('OK'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Use the native app (100 GB)'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Not now'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _limitRow(ThemeData theme, String mode, String limit) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(mode, style: theme.textTheme.bodyMedium),
          const Spacer(),
          Text(
            limit,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Migrate (m27/w27): guest work moves into the account, verified item
/// by item. 0 left behind. Nothing lost.
class MigrateScreen extends StatefulWidget {
  /// Creates the migrate screen.
  const MigrateScreen({super.key});

  @override
  State<MigrateScreen> createState() => _MigrateScreenState();
}

class _MigrateScreenState extends State<MigrateScreen> {
  MigrationResult? _result;
  bool _migrating = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    final historyCount = state.history.real.length;
    final queueCount = state.batch.queued.length;
    return AdaptiveScaffold(
      title: 'Migrate',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Move your guest work into your account.',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Every item is verified as it moves. 0 left behind — '
              'nothing is lost, and the originals stay on this device.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _MigrateRow(
                      label: 'History records',
                      count: historyCount,
                      done: _result != null,
                    ),
                    _MigrateRow(
                      label: 'Queued files',
                      count: queueCount,
                      done: _result != null,
                    ),
                    if (_result != null)
                      _MigrateRow(
                        label: 'Left behind',
                        count: _result!.leftBehind,
                        done: true,
                      ),
                  ],
                ),
              ),
            ),
            if (_result != null) ...[
              const SizedBox(height: 16),
              Text(
                '${_result!.totalMoved} items moved, verified item by '
                'item. 0 left behind.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
            const SizedBox(height: 24),
            if (_result == null)
              FilledButton(
                onPressed: _migrating
                    ? null
                    : () async {
                        setState(() => _migrating = true);
                        await state.history.markAllMigrated();
                        final result = await state.auth.migrate(
                          historyCount: historyCount,
                          queueCount: queueCount,
                        );
                        setState(() {
                          _result = result;
                          _migrating = false;
                        });
                      },
                child: Text(_migrating ? 'Migrating…' : 'Migrate now'),
              )
            else
              FilledButton(
                onPressed: () => Navigator.of(context)
                    .pushReplacementNamed(AppRoutes.account),
                child: const Text('Done — go to your account'),
              ),
            if (_result == null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context)
                    .pushReplacementNamed(AppRoutes.account),
                child: const Text('Skip for now'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One migration row: label, count, checkmark when done.
class _MigrateRow extends StatelessWidget {
  /// Creates a migration row.
  const _MigrateRow({
    required this.label,
    required this.count,
    required this.done,
  });

  /// Row label.
  final String label;

  /// Item count.
  final int count;

  /// True when migrated.
  final bool done;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.circle_outlined,
            color: done ? theme.colorScheme.primary : null,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          Text('$count', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// Account home (m28/w28): synced from this device — encodes, queued,
/// saved.
class AccountHomeScreen extends StatelessWidget {
  /// Creates the account home screen.
  const AccountHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return AdaptiveScaffold(
      title: 'Account',
      body: ListenableBuilder(
        listenable: state.auth,
        builder: (context, _) {
          final account = state.auth.account;
          if (account == null || !state.auth.isSignedIn) {
            return EmptyState(
              icon: Icons.person_outlined,
              headline: 'Not signed in',
              body: 'Sign in to see your account — or keep going as a '
                  'guest. The whole product works either way.',
              actionLabel: 'Sign in',
              onAction: () => Navigator.of(context).pushNamed(
                AppRoutes.authSignIn,
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                account.displayName,
                                style: theme.textTheme.titleLarge,
                              ),
                            ),
                            if (account.verified)
                              Icon(
                                Icons.verified,
                                color: theme.colorScheme.primary,
                              ),
                          ],
                        ),
                        Text(
                          account.email,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Synced from this device',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ListenableBuilder(
                  listenable: state.history,
                  builder: (context, _) {
                    final history = state.history;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _stat(
                              theme,
                              '${history.encodeCount}',
                              'encodes',
                            ),
                            _stat(
                              theme,
                              '${state.batch.queued.length}',
                              'queued',
                            ),
                            _stat(
                              theme,
                              formatBytes(history.totalSaved),
                              'saved',
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.link),
                        title: const Text('Connected'),
                        subtitle: const Text(
                          'Shared links, cloud storage, sign-in methods',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).pushNamed(
                          AppRoutes.accountConnected,
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.shield_outlined),
                        title: const Text('Data controls'),
                        subtitle: const Text(
                          'Export everything, sign out, delete account',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).pushNamed(
                          AppRoutes.accountData,
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.logout),
                        title: const Text('Sign out'),
                        onTap: () async {
                          await state.auth.signOut();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Signed out — guest mode'),
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _stat(ThemeData theme, String value, String label) {
    return Column(
      children: [
        Text(value, style: theme.textTheme.titleLarge),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// Connected (m29/w29): shared links, cloud storage, sign-in methods —
/// each with its own switch.
class ConnectedScreen extends StatelessWidget {
  /// Creates the connected screen.
  const ConnectedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    final auth = state.auth;
    return AdaptiveScaffold(
      title: 'Connected',
      body: ListenableBuilder(
        listenable: auth,
        builder: (context, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ConnectedCard(
                  title: 'Shared links',
                  body: 'Expiring links for encoded PDFs. Links are demo '
                      'records until cloud sharing ships in phase 2.',
                  value: auth.shareLinksEnabled,
                  onChanged: auth.setShareLinksEnabled,
                  footer: TextButton(
                    onPressed: () => Navigator.of(context).pushNamed(
                      AppRoutes.share,
                    ),
                    child: const Text('Manage links'),
                  ),
                ),
                const SizedBox(height: 16),
                _ConnectedCard(
                  title: 'Cloud storage',
                  body: 'Cloud encode up to 50 GB and synced history. '
                      'This switch saves your preference; cloud upload '
                      'ships with the backend in phase 2.',
                  value: auth.cloudStorageEnabled,
                  onChanged: auth.setCloudStorageEnabled,
                ),
                const SizedBox(height: 16),
                _ConnectedCard(
                  title: 'Sign-in methods',
                  body: 'Passkeys for this device. This switch saves '
                      'your preference; passkeys ship with the backend '
                      'in phase 2.',
                  value: auth.passkeysEnabled,
                  onChanged: auth.setPasskeysEnabled,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One connected section: title, explainer, switch, optional footer.
class _ConnectedCard extends StatelessWidget {
  /// Creates a connected section card.
  const _ConnectedCard({
    required this.title,
    required this.body,
    required this.value,
    required this.onChanged,
    this.footer,
  });

  /// Section title.
  final String title;

  /// Explainer text.
  final String body;

  /// Switch value.
  final bool value;

  /// Switch callback.
  final ValueChanged<bool> onChanged;

  /// Optional footer action.
  final Widget? footer;

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
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                Switch.adaptive(value: value, onChanged: onChanged),
              ],
            ),
            const SizedBox(height: 4),
            Text(body, style: theme.textTheme.bodyMedium),
            if (footer != null) ...[
              const SizedBox(height: 8),
              footer!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Data controls (m30/w30): export everything, sign out, or delete the
/// account.
class DataControlsScreen extends StatelessWidget {
  /// Creates the data controls screen.
  const DataControlsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = AppScope.of(context);
    return AdaptiveScaffold(
      title: 'Data controls',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DataCard(
              title: 'Export everything',
              body: 'History, settings and account as one JSON file. '
                  'File bytes and passphrases are never stored, so '
                  'there is nothing else to export.',
              actionLabel: 'Export JSON',
              onAction: () => _export(context, state),
            ),
            const SizedBox(height: 16),
            _DataCard(
              title: 'Sign out',
              body: 'Ends the session on this device. Your guest work '
                  'and local history stay put.',
              actionLabel: 'Sign out',
              onAction: () async {
                await state.auth.signOut();
                if (context.mounted) {
                  popToShell(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Signed out — guest mode'),
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 16),
            _DataCard(
              title: 'Delete the account',
              body: 'Removes the local account profile and session. '
                  'Local history and the queue are kept unless you '
                  'clear them too.',
              actionLabel: 'Delete account',
              dangerous: true,
              onAction: () => _confirmDelete(context, state),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context, AppState state) async {
    final payload = {
      'app': 'Middle Out',
      'version': '0.1',
      'exportedAt': DateTime.now().toIso8601String(),
      'account': state.auth.account?.toJson(),
      'settings': state.settings.toJson(),
      'history': [
        for (final record in state.history.records) record.toJson(),
      ],
      'links': [
        for (final link in state.links.links) link.toJson(),
      ],
    };
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)),
    );
    final name =
        'middleout-export-${DateTime.now().millisecondsSinceEpoch}.json';
    try {
      await saveFileBytes(bytes, name, mimeType: 'application/json');
      await ShareService.shareBytes(bytes, name, 'application/json');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  Future<void> _confirmDelete(BuildContext context, AppState state) async {
    var clearLocalData = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Delete the account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This removes the local account profile and session. '
                'It cannot be undone.',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                title: const Text('Also clear local history and queue'),
                value: clearLocalData,
                contentPadding: EdgeInsets.zero,
                onChanged: (value) => setDialogState(
                  () => clearLocalData = value ?? false,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await state.auth.deleteAccount();
    if (clearLocalData) {
      await state.history.clearAll(includeDemo: true);
      await state.batch.clearAll();
      await state.links.clearAll();
    }
    if (context.mounted) {
      popToShell(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account deleted')),
      );
    }
  }
}

/// One data-control block: title, explainer, action.
class _DataCard extends StatelessWidget {
  /// Creates a data-control card.
  const _DataCard({
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
    this.dangerous = false,
  });

  /// Card title.
  final String title;

  /// Explainer text.
  final String body;

  /// Action label.
  final String actionLabel;

  /// Action callback.
  final VoidCallback onAction;

  /// True for the destructive action (red label).
  final bool dangerous;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(body, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onAction,
              child: Text(
                actionLabel,
                style: dangerous
                    ? TextStyle(color: theme.colorScheme.error)
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
