/// A compact summary row describing which messages a peer is missing.
///
/// Summaries reduce redundant retransmission, but they are explicitly *not*
/// treated as proof of delivery: only a signed delivery receipt is.
class PeerSummaryEntry {
  const PeerSummaryEntry({
    required this.bundleIdHex,
    required this.expiresAtMs,
  });

  final String bundleIdHex;
  final int expiresAtMs;
}

/// A bounded summary exchanged with a peer after identity / capability
/// negotiation.
class PeerSummary {
  const PeerSummary({
    required this.identityId,
    required this.entries,
    required this.generatedAtMs,
  });

  final String identityId;
  final List<PeerSummaryEntry> entries;
  final int generatedAtMs;

  Set<String> get bundleIds => {for (final e in entries) e.bundleIdHex};

  Map<String, Object?> toCbor() => {
    'id': identityId,
    'gen': generatedAtMs,
    'entries': [
      for (final entry in entries)
        {'bid': entry.bundleIdHex, 'exp': entry.expiresAtMs},
    ],
  };

  static PeerSummary fromCbor(Map<String, Object?> map) {
    final raw = (map['entries'] as List).cast<Map>();
    return PeerSummary(
      identityId: map['id'] as String,
      generatedAtMs: map['gen'] as int,
      entries: [
        for (final entry in raw)
          PeerSummaryEntry(
            bundleIdHex: entry['bid'] as String,
            expiresAtMs: entry['exp'] as int,
          ),
      ],
    );
  }
}
