import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A dismissible inline error banner.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, this.onDismiss});

  final String message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            if (onDismiss != null)
              IconButton(
                tooltip: 'Dismiss',
                icon: Icon(Icons.close, color: scheme.onErrorContainer),
                onPressed: onDismiss,
              ),
          ],
        ),
      ),
    );
  }
}

/// A positive informational banner.
class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.message, this.onDismiss});

  final String message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: scheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              icon: Icon(Icons.close, color: scheme.onSecondaryContainer),
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}

/// A centred empty-state placeholder with an optional call to action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// A full-screen loading indicator with a label.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.label = 'Loading…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label),
        ],
      ),
    );
  }
}

/// A titled, elevated section used across the settings-style screens.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// A labelled key/value row.
class DetailRow extends StatelessWidget {
  const DetailRow({
    super.key,
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              value,
              style: monospace
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders PNG bytes losslessly at their intrinsic size.
class PngPreview extends StatelessWidget {
  const PngPreview({super.key, required this.bytes, this.width, this.height});

  final Uint8List bytes;
  final int? width;
  final int? height;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260, maxHeight: 320),
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        semanticLabel: 'Image attachment',
      ),
    );
  }
}

/// Formats a byte count for display.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Formats an epoch-millis timestamp as a short, human local time.
///
/// Today shows just the clock time, yesterday is prefixed, and older messages
/// use a readable date instead of an ISO-style string.
String formatTimestamp(int epochMs) {
  final time = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final now = DateTime.now();
  final hm = _hhmm(time);
  final dayDiff = _dayNumber(now) - _dayNumber(time);
  if (dayDiff == 0) return hm;
  if (dayDiff == 1) return 'Yesterday $hm';
  if (time.year == now.year) return '${time.day} ${_monthName(time.month)} $hm';
  return '${time.day} ${_monthName(time.month)} ${time.year} $hm';
}

/// A date-divider label for the conversation list: Today / Yesterday / date.
String formatDayLabel(int epochMs) {
  final time = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final now = DateTime.now();
  final dayDiff = _dayNumber(now) - _dayNumber(time);
  if (dayDiff == 0) return 'Today';
  if (dayDiff == 1) return 'Yesterday';
  if (time.year == now.year) return '${time.day} ${_monthName(time.month)}';
  return '${time.day} ${_monthName(time.month)} ${time.year}';
}

/// Whether two epoch-millis values fall on the same local calendar day.
bool isSameLocalDay(int aMs, int bMs) {
  final a = DateTime.fromMillisecondsSinceEpoch(aMs);
  final b = DateTime.fromMillisecondsSinceEpoch(bMs);
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _hhmm(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

int _dayNumber(DateTime time) =>
    DateTime(time.year, time.month, time.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _monthName(int month) => _months[month - 1];

/// Remaining lifetime of a message, or 'expired'.
String formatRemaining(int expiresAtMs) {
  final remaining = expiresAtMs - DateTime.now().millisecondsSinceEpoch;
  if (remaining <= 0) return 'expired';
  final minutes = remaining ~/ 60000;
  if (minutes < 60) return 'expires in ${minutes}m';
  final hours = minutes ~/ 60;
  return 'expires in ${hours}h ${minutes % 60}m';
}
