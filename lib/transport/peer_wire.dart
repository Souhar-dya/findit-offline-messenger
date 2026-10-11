import 'dart:typed_data';

import '../core/cbor/canonical_cbor.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/bytes.dart';
import '../crypto/identity_record.dart';
import '../domain/entities/peer_summary.dart';
import 'transport.dart';

/// CBOR payload codecs for the post-connect wire exchange.
///
/// These run over the opaque frames of `frame_stream.dart`, so the same
/// protocol is shared by every transport implementation (simulated, platform
/// channel, and any future socket transport). Only public identity material is
/// exchanged: the identity *record* (public keys + display name) is sent, never
/// a private key.

const String _handshakeIdentityKey = 'identity';
const String _handshakeCapsKey = 'caps';

/// Encodes an identity + capability handshake into a frame payload.
Uint8List encodeHandshakePayload(PeerHandshakeRequest request) =>
    CanonicalCbor.encode({
      _handshakeIdentityKey: request.identity.encode(),
      _handshakeCapsKey: request.capabilities,
    });

/// Decodes a handshake frame payload back into a request. Malformed input
/// throws [ProtocolException] or [CryptoException].
PeerHandshakeRequest decodeHandshakePayload(List<int> bytes) {
  final map = CanonicalCbor.decode(bytes);
  final identityBytes = map[_handshakeIdentityKey];
  final caps = map[_handshakeCapsKey];
  if (identityBytes is! List<int> || caps is! List) {
    throw const ProtocolException('Malformed handshake payload');
  }
  final identity = IdentityRecord.fromCbor(
    CanonicalCbor.decode(asUint8List(identityBytes)),
  );
  return PeerHandshakeRequest(
    identity: identity,
    capabilities: caps.cast<String>().toList(),
  );
}

/// Encodes a compact peer summary into a frame payload.
Uint8List encodeSummaryPayload(PeerSummary summary) =>
    CanonicalCbor.encode(summary.toCbor());

/// Decodes a peer summary frame payload.
PeerSummary decodeSummaryPayload(List<int> bytes) =>
    PeerSummary.fromCbor(CanonicalCbor.decode(bytes));
