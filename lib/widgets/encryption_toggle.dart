import 'package:material_ui/material_ui.dart';

/// Encryption toggle + passphrase field. Default ON.
///
/// Encrypted payload is not human-readable when scanned; plain payload is.
/// The passphrase never leaves the device — it derives the ChaCha20 key
/// locally (PBKDF2) and is never stored.
class EncryptionToggle extends StatelessWidget {
  /// Creates an encryption toggle with the current [encrypted] state and
  /// [passphrase], reporting changes via the callbacks.
  const EncryptionToggle({
    required this.encrypted,
    required this.passphrase,
    required this.onEncryptedChanged,
    required this.onPassphraseChanged,
    super.key,
  });

  /// Whether the payload is encrypted (default ON).
  final bool encrypted;

  /// The current passphrase text (never stored).
  final String passphrase;

  /// Called when the encryption switch flips.
  final ValueChanged<bool> onEncryptedChanged;

  /// Called when the passphrase text changes.
  final ValueChanged<String> onPassphraseChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          title: Text('Encrypt payload', style: theme.textTheme.titleMedium),
          subtitle: Text(
            encrypted
                ? 'Scanned frames reveal nothing without the passphrase.'
                : 'Plain — anyone who scans the frames can read the payload.',
            style: theme.textTheme.bodySmall,
          ),
          value: encrypted,
          contentPadding: EdgeInsets.zero,
          onChanged: onEncryptedChanged,
        ),
        if (encrypted) ...[
          const SizedBox(height: 4),
          TextField(
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Passphrase',
              hintText: 'Needed to decode — keep it safe',
              border: OutlineInputBorder(),
            ),
            onChanged: onPassphraseChanged,
          ),
          const SizedBox(height: 6),
          Text(
            'The passphrase derives the key on this device and is never '
            'stored or uploaded. Lose it and the frames cannot be decoded.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
