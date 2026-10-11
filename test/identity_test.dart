import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:findit/core/errors/app_exception.dart';
import 'package:findit/crypto/identity_record.dart';
import 'package:findit/crypto/identity_service.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';

IdentityService serviceWith(SecretStore store) =>
    IdentityService(secretStore: store);

IdentityRecord copyRecord(
  IdentityRecord record, {
  int? formatVersion,
  int? keyVersion,
  String? identityId,
  Uint8List? signingPublicKey,
  Uint8List? agreementPublicKey,
  String? displayName,
  Uint8List? signature,
}) {
  return IdentityRecord(
    formatVersion: formatVersion ?? record.formatVersion,
    keyVersion: keyVersion ?? record.keyVersion,
    identityId: identityId ?? record.identityId,
    signingPublicKey: signingPublicKey ?? record.signingPublicKey,
    agreementPublicKey: agreementPublicKey ?? record.agreementPublicKey,
    displayName: displayName ?? record.displayName,
    signature: signature ?? record.signature,
  );
}

void main() {
  group('Identity generation and persistence', () {
    test('generates a signed, self-bound identity record', () async {
      final identity = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      final record = identity.record;

      expect(record.identityId, startsWith('fid_'));
      expect(record.identityId.length, 'fid_'.length + 32);
      expect(record.signingPublicKey.length, 32);
      expect(record.agreementPublicKey.length, 32);
      expect(record.signature.length, 64);
      expect(await record.verify(), isTrue);
      expect(await record.isIdBound(), isTrue);
    });

    test('derives the identity id from the signing public key', () async {
      final identity = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      expect(
        await IdentityRecord.deriveId(identity.record.signingPublicKey),
        identity.record.identityId,
      );
    });

    test('persists and reloads the same identity', () async {
      final store = InMemorySecretStore();
      final service = serviceWith(store);
      final identity = await service.generate(displayName: 'Alice');
      expect(await service.hasIdentity(), isTrue);

      final reloaded = await service.load();
      expect(reloaded, isNotNull);
      expect(reloaded!.identityId, identity.identityId);
      expect(reloaded.displayName, 'Alice');
      expect(await reloaded.record.verify(), isTrue);

      final signing = await reloaded.signingKeyPair.extractPublicKey();
      expect(signing.bytes, identity.record.signingPublicKey);
      final agreement = await reloaded.agreementKeyPair.extractPublicKey();
      expect(agreement.bytes, identity.record.agreementPublicKey);
    });

    test('load returns null before any identity exists', () async {
      final service = serviceWith(InMemorySecretStore());
      expect(await service.load(), isNull);
      expect(await service.hasIdentity(), isFalse);
    });

    test('two generated identities are distinct', () async {
      final a = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'A');
      final b = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'B');
      expect(a.identityId, isNot(b.identityId));
      expect(a.record.signingPublicKey, isNot(b.record.signingPublicKey));
    });

    test('the public record contains no private key material', () async {
      final identity = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      expect(identity.record.toCbor().keys.toSet(), {
        'v',
        'kv',
        'id',
        'ik',
        'ak',
        'name',
        'sig',
      });
    });

    test('rename re-signs the record but keeps the identity id', () async {
      final service = serviceWith(InMemorySecretStore());
      final identity = await service.generate(displayName: 'Alice');
      final renamed = await service.rename(identity, 'Alice Cooper');

      expect(renamed.identityId, identity.identityId);
      expect(renamed.displayName, 'Alice Cooper');
      expect(renamed.record.signingPublicKey, identity.record.signingPublicKey);
      expect(await renamed.record.verify(), isTrue);

      final reloaded = await service.load();
      expect(reloaded!.displayName, 'Alice Cooper');
    });

    test('delete removes the persisted identity', () async {
      final service = serviceWith(InMemorySecretStore());
      await service.generate(displayName: 'Alice');
      await service.delete();
      expect(await service.hasIdentity(), isFalse);
      expect(await service.load(), isNull);
    });
  });

  group('Signatures and tamper resistance', () {
    test(
      'verifies a signature over a message and rejects a tampered payload',
      () async {
        final identity = await serviceWith(
          InMemorySecretStore(),
        ).generate(displayName: 'Alice');
        final message = utf8.encode('hello world');
        final signature = await identity.sign(message);
        final publicKey = SimplePublicKey(
          identity.record.signingPublicKey,
          type: KeyPairType.ed25519,
        );

        expect(
          await Ed25519().verify(
            message,
            signature: Signature(signature, publicKey: publicKey),
          ),
          isTrue,
        );
        expect(
          await Ed25519().verify(
            utf8.encode('hello worle'),
            signature: Signature(signature, publicKey: publicKey),
          ),
          isFalse,
        );
      },
    );

    test('rejects a record whose display name changed after signing', () async {
      final identity = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      final tampered = copyRecord(identity.record, displayName: 'Mallory');
      expect(await tampered.verify(), isFalse);
    });

    test('rejects a record whose signing key was swapped', () async {
      final alice = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      final mallory = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Mallory');
      final tampered = copyRecord(
        alice.record,
        signingPublicKey: mallory.record.signingPublicKey,
      );
      expect(await tampered.verify(), isFalse);
    });

    test('rejects a record whose id does not match its key', () async {
      final identity = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      final tampered = copyRecord(
        identity.record,
        identityId: 'fid_00000000000000000000000000000000',
      );
      expect(await tampered.verify(), isFalse);
      expect(await tampered.isIdBound(), isFalse);
    });

    test('rejects a truncated signature', () async {
      final identity = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      final tampered = copyRecord(
        identity.record,
        signature: Uint8List.fromList(identity.record.signature.sublist(0, 32)),
      );
      expect(await tampered.verify(), isFalse);
    });

    test('parseAndVerify throws for a tampered record', () async {
      final identity = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      final tampered = copyRecord(identity.record, displayName: 'Mallory');
      expect(
        () => IdentityRecord.parseAndVerify(tampered.encode()),
        throwsA(isA<CryptoException>()),
      );
    });
  });

  group('QR export and import', () {
    test('round-trips public data only', () async {
      final identity = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      final parsed = IdentityRecord.parseQrData(identity.record.toQrData());

      expect(parsed.identityId, identity.record.identityId);
      expect(parsed.displayName, 'Alice');
      expect(parsed.signingPublicKey, identity.record.signingPublicKey);
      expect(parsed.agreementPublicKey, identity.record.agreementPublicKey);
      expect(await parsed.verify(), isTrue);
    });

    test('accepts an optional findit:// scheme prefix', () async {
      final identity = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      final parsed = IdentityRecord.parseQrData(
        'findit://${identity.record.toQrData()}',
      );
      expect(parsed.identityId, identity.record.identityId);
    });

    test('rejects input that is not base64', () {
      expect(
        () => IdentityRecord.parseQrData('!!! not base64 !!!'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rejects a tampered QR payload', () async {
      final identity = await serviceWith(
        InMemorySecretStore(),
      ).generate(displayName: 'Alice');
      final tampered = copyRecord(identity.record, displayName: 'Mallory');
      expect(await tampered.verify(), isFalse);
      expect(
        () => IdentityRecord.parseAndVerify(tampered.encode()),
        throwsA(isA<CryptoException>()),
      );
    });
  });
}
