import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// A camera page that scans a FindIt identity QR code and pops with the raw
/// payload string.
///
/// Camera permission is requested by the plugin. On platforms without a camera
/// (or when permission is denied) the error builder explains the problem
/// instead of failing silently. QR scanning is optional: identities can also be
/// added by pasting their payload.
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key, this.title = 'Scan identity QR'});

  final String title;

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(raw);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _ScannerError(error: error),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.all(16),
              child: const Text(
                'Point the camera at a FindIt identity QR code.',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 48),
            const SizedBox(height: 12),
            Text(
              'Camera unavailable',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '${error.errorCode.name}: ${error.errorDetails?.message ?? 'unknown error'}',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'You can still add a contact by pasting their identity payload.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
