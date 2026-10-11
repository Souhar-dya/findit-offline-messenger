import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'common.dart';

/// Displays a public identity record as a QR code plus its human-readable id.
///
/// The QR payload is the canonical public record only. Private keys never leave
/// secure storage and are never rendered or exported.
class IdentityQrView extends StatelessWidget {
  const IdentityQrView({
    super.key,
    required this.qrData,
    required this.identityId,
    required this.displayName,
    this.caption = 'Scan this code on another device to add this identity.',
  });

  final String qrData;
  final String identityId;
  final String displayName;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(
            data: qrData,
            version: QrVersions.auto,
            size: 220,
            backgroundColor: Colors.white,
            errorStateBuilder: (context, error) => SizedBox(
              width: 220,
              height: 220,
              child: Center(child: Text('Could not render QR: $error')),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(displayName, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          caption,
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        DetailRow(label: 'Identity', value: identityId, monospace: true),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: identityId));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Identity id copied')),
              );
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy identity id'),
        ),
      ],
    );
  }
}
