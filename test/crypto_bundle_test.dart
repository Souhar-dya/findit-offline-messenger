import 'dart:convert';
import 'dart:typed_data';

import 'package:findit/core/cbor/canonical_cbor.dart';
import 'package:findit/core/errors/app_exception.dart';
import 'package:findit/core/protocol/envelope.dart';
import 'package:findit/core/utils/bytes.dart';
import 'package:findit/crypto/message_crypto.dart';
import 'package:findit/messaging/message_factory.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Uint8List flipFirst(Uint8List bytes) {
  final copy = Uint8List.fromList(bytes);
  if (copy.isNotEmpty) copy[0] = copy[0] ^ 0xFF;
  return copy;
}

Envelope withFields(
  Envelope envelope, {
  Uint8List? cipherText,
  int? expiresAtMs,
}) {
  return Envelope(
    version: envelope.version,
    type: envelope.type,
    bundleId: envelope.bundleId,
    recipientId: envelope.recipientId,
    expiresAtMs: expiresAtMs ?? envelope.expiresAtMs,
    cipherText: cipherText ?? envelope.cipherText,
    mac: envelope.mac,
    nonce: envelope.nonce,
    ephemeralPublicKey: envelope.ephemeralPublicKey,
    algorithm: envelope.algorithm,
    kdf: envelope.kdf,
  );
}

void main() {
  late TestNode alice;
  late TestNode bob;
  late TestNode carol;

  setUp(() async {
    alice = await TestNode.create();
    bob = await TestNode.create();
    carol = await TestNode.create();
    await alice.createIdentity('Alice');
    await bob.createIdentity('Bob');
    await carol.createIdentity('Carol');
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
    await carol.dispose();
  });

  group('Canonical CBOR', () {
    test('round-trips a map', () {
      final bytes = CanonicalCbor.encode({'b': 2, 'a': 1});
      expect(CanonicalCbor.decode(bytes), {'a': 1, 'b': 2});
    });

    test('decodes canonical key order', () {
      // {"a": 1}
      final canonical = Uint8List.fromList([0xA1, 0x61, 0x61, 0x01]);
      expect(CanonicalCbor.decode(canonical), {'a': 1});
    });

    test('rejects a non-canonical key order', () {
      // {"b": 2, "a": 1} encoded with the keys out of canonical order.
      final nonCanonical = Uint8List.fromList([
        0xA2,
        0x61,
        0x62,
        0x02,
        0x61,
        0x61,
        0x01,
      ]);
      expect(
        () => CanonicalCbor.decode(nonCanonical),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects malformed CBOR', () {
      expect(
        () => CanonicalCbor.decode(Uint8List.fromList([0xFF, 0x00])),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('BundleCodec', () {
    Uint8List id() => randomBytes(16);

    test('seals and opens a text bundle', () async {
      final bundleId = id();
      final now = alice.clock.now().millisecondsSinceEpoch;
      final payload = MessageFactory.buildText(
        messageIdHex: bytesToHex(bundleId),
        createdAtMs: now,
        expiresAtMs: now + 600000,
        text: 'hello bob',
      );
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.message,
        payload: payload,
        bundleId: bundleId,
      );
      final opened = await bob.open(bytes);

      expect(opened.sender.identityId, alice.id);
      expect(opened.type, EnvelopeType.message);
      expect(opened.bundleId, bundleId);
      expect(opened.payload[MessageFields.text], 'hello bob');
    });

    test('refuses a bundle addressed to another identity', () async {
      final bundleId = id();
      final now = alice.clock.now().millisecondsSinceEpoch;
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.message,
        payload: MessageFactory.buildText(
          messageIdHex: bytesToHex(bundleId),
          createdAtMs: now,
          expiresAtMs: now + 600000,
          text: 'x',
        ),
        bundleId: bundleId,
      );
      expect(() => carol.open(bytes), throwsA(isA<ProtocolException>()));
    });

    test('refuses an expired bundle but honours the exact boundary', () async {
      final bundleId = id();
      final t0 = alice.clock.now();
      final expires = t0.add(const Duration(hours: 24));
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.message,
        payload: MessageFactory.buildText(
          messageIdHex: bytesToHex(bundleId),
          createdAtMs: t0.millisecondsSinceEpoch,
          expiresAtMs: expires.millisecondsSinceEpoch,
          text: 'boundary',
        ),
        bundleId: bundleId,
        expiresAtMs: expires.millisecondsSinceEpoch,
      );

      bob.clock.setTo(expires.subtract(const Duration(milliseconds: 1)));
      final opened = await bob.open(bytes);
      expect(opened.sender.identityId, alice.id);

      bob.clock.setTo(expires);
      expect(() => bob.open(bytes), throwsA(isA<ExpiredException>()));
    });

    test('rejects a tampered ciphertext', () async {
      final bundleId = id();
      final now = alice.clock.now().millisecondsSinceEpoch;
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.message,
        payload: MessageFactory.buildText(
          messageIdHex: bytesToHex(bundleId),
          createdAtMs: now,
          expiresAtMs: now + 600000,
          text: 'secret',
        ),
        bundleId: bundleId,
      );
      final envelope = Envelope.decode(bytes);
      final tampered = withFields(
        envelope,
        cipherText: flipFirst(envelope.cipherText),
      );
      expect(
        () => bob.open(tampered.encode()),
        throwsA(isA<CryptoException>()),
      );
    });

    test('binds the immutable routing fields as associated data', () async {
      final bundleId = id();
      final now = alice.clock.now().millisecondsSinceEpoch;
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.message,
        payload: MessageFactory.buildText(
          messageIdHex: bytesToHex(bundleId),
          createdAtMs: now,
          expiresAtMs: now + 600000,
          text: 'secret',
        ),
        bundleId: bundleId,
      );
      final envelope = Envelope.decode(bytes);
      // Change a routing field covered by the AEAD; decryption must fail.
      final tampered = withFields(
        envelope,
        expiresAtMs: envelope.expiresAtMs - 1,
      );
      expect(
        () => bob.open(tampered.encode()),
        throwsA(isA<CryptoException>()),
      );
    });

    test('rejects a bundle whose inner signature is invalid', () async {
      final bundleId = id();
      final now = alice.clock.now().millisecondsSinceEpoch;
      final expiresAt = now + 600000;
      final inner = <String, Object?>{
        'v': 1,
        'typ': EnvelopeType.message.wire,
        'rec': alice.identity!.record.toCbor(),
        'pl': MessageFactory.buildText(
          messageIdHex: bytesToHex(bundleId),
          createdAtMs: now,
          expiresAtMs: expiresAt,
          text: 'forged',
        ),
        'sig': randomBytes(64),
      };
      final associatedData = Envelope.associatedDataFor(
        version: 1,
        type: EnvelopeType.message,
        bundleId: bundleId,
        recipientId: bob.id,
        expiresAtMs: expiresAt,
      );
      final encrypted = await MessageCrypto().encrypt(
        recipient: bob.identity!.record,
        plaintext: CanonicalCbor.encode(inner),
        associatedData: associatedData,
      );
      final envelope = Envelope(
        version: 1,
        type: EnvelopeType.message,
        bundleId: bundleId,
        recipientId: bob.id,
        expiresAtMs: expiresAt,
        cipherText: encrypted.cipherText,
        mac: encrypted.mac,
        nonce: encrypted.nonce,
        ephemeralPublicKey: encrypted.ephemeralPublicKey,
      );
      expect(
        () => bob.open(envelope.encode()),
        throwsA(isA<CryptoException>()),
      );
    });

    test('rejects a bundle with an invalid sender record', () async {
      final bundleId = id();
      final now = alice.clock.now().millisecondsSinceEpoch;
      final expiresAt = now + 600000;
      // A forged identity record that will not verify.
      final forged = {...alice.identity!.record.toCbor(), 'name': 'Not Alice'};
      final signed = <String, Object?>{
        'v': 1,
        'typ': EnvelopeType.message.wire,
        'rec': forged,
        'pl': MessageFactory.buildText(
          messageIdHex: bytesToHex(bundleId),
          createdAtMs: now,
          expiresAtMs: expiresAt,
          text: 'spoof',
        ),
        'sig': await alice.identity!.sign(Uint8List(0)),
      };
      final associatedData = Envelope.associatedDataFor(
        version: 1,
        type: EnvelopeType.message,
        bundleId: bundleId,
        recipientId: bob.id,
        expiresAtMs: expiresAt,
      );
      final encrypted = await MessageCrypto().encrypt(
        recipient: bob.identity!.record,
        plaintext: CanonicalCbor.encode(signed),
        associatedData: associatedData,
      );
      final envelope = Envelope(
        version: 1,
        type: EnvelopeType.message,
        bundleId: bundleId,
        recipientId: bob.id,
        expiresAtMs: expiresAt,
        cipherText: encrypted.cipherText,
        mac: encrypted.mac,
        nonce: encrypted.nonce,
        ephemeralPublicKey: encrypted.ephemeralPublicKey,
      );
      expect(
        () => bob.open(envelope.encode()),
        throwsA(isA<CryptoException>()),
      );
    });
  });

  group('MessageCrypto (ECIES)', () {
    test('round-trips for the intended recipient only', () async {
      final crypto = MessageCrypto();
      final associatedData = Uint8List(0);
      final plaintext = Uint8List.fromList(
        utf8.encode('a very secret payload'),
      );

      final encrypted = await crypto.encrypt(
        recipient: bob.identity!.record,
        plaintext: plaintext,
        associatedData: associatedData,
      );
      final decrypted = await crypto.decrypt(
        recipient: bob.identity!,
        payload: encrypted,
        associatedData: associatedData,
      );
      expect(decrypted, plaintext);

      expect(
        () => crypto.decrypt(
          recipient: carol.identity!,
          payload: encrypted,
          associatedData: associatedData,
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('fails when the associated data changes', () async {
      final crypto = MessageCrypto();
      final plaintext = Uint8List.fromList(utf8.encode('bound data'));
      final encrypted = await crypto.encrypt(
        recipient: bob.identity!.record,
        plaintext: plaintext,
        associatedData: Uint8List.fromList([1, 2, 3]),
      );
      expect(
        () => crypto.decrypt(
          recipient: bob.identity!,
          payload: encrypted,
          associatedData: Uint8List.fromList([1, 2, 4]),
        ),
        throwsA(isA<CryptoException>()),
      );
    });
  });
}
