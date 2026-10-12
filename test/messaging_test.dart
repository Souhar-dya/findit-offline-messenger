import 'dart:typed_data';

import 'package:findit/core/config/app_config.dart';
import 'package:findit/core/errors/app_exception.dart';
import 'package:findit/core/protocol/envelope.dart';
import 'package:findit/core/utils/bytes.dart';
import 'package:findit/domain/entities/chat_message.dart';
import 'package:findit/messaging/message_factory.dart';
import 'package:findit/messaging/message_service.dart';
import 'package:findit/messaging/png_validator.dart';
import 'package:findit/messaging/receipt_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/png.dart';

void main() {
  late TestNode alice;
  late TestNode bob;

  setUp(() async {
    alice = await TestNode.create();
    bob = await TestNode.create();
    await alice.createIdentity('Alice');
    await bob.createIdentity('Bob');
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  group('Text messaging', () {
    test('delivers a message and confirms it with a signed receipt', () async {
      final message = await alice.core.messageService.sendText(
        recipient: bob.identity!.record,
        text: 'Hello Bob',
      );
      expect(message.status, MessageStatus.queued);

      final stored = await alice.storedBundle(message.id);
      final received = await bob.core.messageService.handleIncoming(
        await bob.open(stored.bytes),
      );
      expect(received, MessageInboundOutcome.stored);

      final storedOnBob = await bob.core.messages.find(message.id);
      expect(storedOnBob!.text, 'Hello Bob');
      expect(storedOnBob.direction, MessageDirection.incoming);
      expect(storedOnBob.senderId, alice.id);

      final receiptBundle = await firstBundleOfType(
        bob,
        EnvelopeType.deliveryReceipt,
      );
      final result = await alice.core.receiptService.handleIncoming(
        await alice.open(receiptBundle.bytes),
      );
      expect(result, ReceiptInboundResult.delivered);

      final delivered = await alice.core.messages.find(message.id);
      expect(delivered!.status, MessageStatus.delivered);
      expect(delivered.deliveredAtMs, isNotNull);
      expect(await alice.core.bundles.hasTombstone(message.id), isTrue);
    });

    test('stores a duplicate message once but still acknowledges it', () async {
      final message = await alice.core.messageService.sendText(
        recipient: bob.identity!.record,
        text: 'dedup me',
      );
      final bytes = (await alice.storedBundle(message.id)).bytes;

      expect(
        await bob.core.messageService.handleIncoming(await bob.open(bytes)),
        MessageInboundOutcome.stored,
      );
      expect(
        await bob.core.messageService.handleIncoming(await bob.open(bytes)),
        MessageInboundOutcome.duplicate,
      );
      expect((await bob.core.messages.conversation(alice.id)).length, 1);
      expect(
        (await bob.core.receipts.receiptsForMessage(message.id)).length,
        1,
      );
    });

    test('rejects sending to yourself and empty text', () async {
      expect(
        () => alice.core.messageService.sendText(
          recipient: alice.identity!.record,
          text: 'self',
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => alice.core.messageService.sendText(
          recipient: bob.identity!.record,
          text: '   ',
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('retries outbound messages without duplicating them', () async {
      final message = await alice.core.messageService.sendText(
        recipient: bob.identity!.record,
        text: 'retry me',
      );
      final bytesBefore = await alice.core.bundles.totalBytes();

      expect(await alice.core.messageService.retryOutbound(), 1);

      expect(await alice.core.bundles.totalBytes(), bytesBefore);
      expect((await alice.core.messages.conversation(bob.id)).length, 1);
      expect(
        (await alice.core.messages.find(message.id))!.status,
        MessageStatus.queued,
      );
    });

    test('marks a relayed message as unconfirmed, never delivered', () async {
      final message = await alice.core.messageService.sendText(
        recipient: bob.identity!.record,
        text: 'relayed',
      );
      await alice.core.messageService.markRelayed(message.id);
      expect(
        (await alice.core.messages.find(message.id))!.status,
        MessageStatus.unconfirmed,
      );
    });

    test('read state is local and separate from delivery receipts', () async {
      final message = await alice.core.messageService.sendText(
        recipient: bob.identity!.record,
        text: 'read me',
      );
      await bob.core.messageService.handleIncoming(
        await bob.open((await alice.storedBundle(message.id)).bytes),
      );

      await bob.core.messageService.markRead(alice.id);
      final received = await bob.core.messages.find(message.id);
      expect(received!.readAtMs, isNotNull);
      // Only the delivery receipt exists; no read receipt is produced.
      expect(
        (await bob.core.receipts.receiptsForMessage(message.id)).length,
        1,
      );
      // Read state does not fabricate a "delivered" status on the sender.
      expect(
        (await alice.core.messages.find(message.id))!.status,
        MessageStatus.queued,
      );
    });

    test('notifies listeners when sent and when confirmed delivered', () async {
      final events = <void>[];
      final subscription = alice.core.messageChanges.stream.listen(events.add);
      addTearDown(subscription.cancel);

      final message = await alice.core.messageService.sendText(
        recipient: bob.identity!.record,
        text: 'ping',
      );
      await bob.core.messageService.handleIncoming(
        await bob.open((await alice.storedBundle(message.id)).bytes),
      );
      final receipt = await firstBundleOfType(bob, EnvelopeType.deliveryReceipt);
      await alice.core.receiptService.handleIncoming(
        await alice.open(receipt.bytes),
      );
      await pumpEventQueue();

      // One notification for the send and one for the delivered receipt.
      expect(events.length, greaterThanOrEqualTo(2));
      expect(
        (await alice.core.messages.find(message.id))!.status,
        MessageStatus.delivered,
      );
    });
  });

  group('Conversation ordering', () {
    test('orders by the local clock, not the sender clock', () async {
      // Bob's clock is behind: his reply is created "earlier" but arrives after
      // Alice's own message. Ordering must follow what this device observed.
      final mine = ChatMessage(
        id: 'aa000000000000000000000000000001',
        senderId: alice.id,
        recipientId: bob.id,
        peerId: bob.id,
        direction: MessageDirection.outgoing,
        status: MessageStatus.delivered,
        payloadType: MessagePayloadType.text,
        createdAtMs: 2000,
        expiresAtMs: 999999,
        text: 'mine',
      );
      final theirs = ChatMessage(
        id: 'aa000000000000000000000000000002',
        senderId: bob.id,
        recipientId: alice.id,
        peerId: bob.id,
        direction: MessageDirection.incoming,
        status: MessageStatus.received,
        payloadType: MessagePayloadType.text,
        createdAtMs: 1500,
        expiresAtMs: 999999,
        text: 'theirs',
        receivedAtMs: 2500,
      );

      expect(await alice.core.messages.insertIfAbsent(theirs), isTrue);
      expect(await alice.core.messages.insertIfAbsent(mine), isTrue);

      final ordered = await alice.core.messages.conversation(bob.id);
      expect(ordered.map((message) => message.id), [mine.id, theirs.id]);
    });
  });

  group('TTL and validation', () {
    test(
      'enforces the 24h TTL boundary and never resets it on relay',
      () async {
        final sender = await TestNode.create(config: AppConfig.production);
        final receiver = await TestNode.create(config: AppConfig.production);
        try {
          await sender.createIdentity('Sender');
          await receiver.createIdentity('Receiver');
          final t0 = sender.clock.now();

          final message = await sender.core.messageService.sendText(
            recipient: receiver.identity!.record,
            text: 'ttl',
          );
          expect(
            message.expiresAtMs - message.createdAtMs,
            const Duration(hours: 24).inMilliseconds,
          );

          // Relaying stores the immutable bytes unchanged.
          final bytes = (await sender.storedBundle(message.id)).bytes;
          expect(Envelope.decode(bytes).expiresAtMs, message.expiresAtMs);

          receiver.clock.setTo(
            t0
                .add(const Duration(hours: 24))
                .subtract(const Duration(milliseconds: 1)),
          );
          expect(
            await receiver.core.messageService.handleIncoming(
              await receiver.open(bytes),
            ),
            MessageInboundOutcome.stored,
          );

          receiver.clock.setTo(t0.add(const Duration(hours: 24)));
          expect(() => receiver.open(bytes), throwsA(isA<ExpiredException>()));
        } finally {
          await sender.dispose();
          await receiver.dispose();
        }
      },
    );

    test('rejects a message that extends the TTL beyond the maximum', () async {
      final now = alice.clock.now().millisecondsSinceEpoch;
      final bundleId = randomBytes(16);
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.message,
        bundleId: bundleId,
        expiresAtMs: now + const Duration(hours: 20).inMilliseconds,
        payload: MessageFactory.buildText(
          messageIdHex: bytesToHex(bundleId),
          createdAtMs: now - const Duration(hours: 20).inMilliseconds,
          expiresAtMs: now + const Duration(hours: 20).inMilliseconds,
          text: 'stale',
        ),
      );
      expect(
        await bob.core.messageService.handleIncoming(await bob.open(bytes)),
        MessageInboundOutcome.invalid,
      );
    });

    test('rejects a message whose id does not match the bundle id', () async {
      final now = alice.clock.now().millisecondsSinceEpoch;
      final bundleId = randomBytes(16);
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.message,
        bundleId: bundleId,
        payload: MessageFactory.buildText(
          messageIdHex: bytesToHex(randomBytes(16)),
          createdAtMs: now,
          expiresAtMs: now + 600000,
          text: 'mismatch',
        ),
      );
      expect(
        await bob.core.messageService.handleIncoming(await bob.open(bytes)),
        MessageInboundOutcome.invalid,
      );
    });

    test('rejects a message addressed to another identity', () async {
      final carol = await TestNode.create();
      await carol.createIdentity('Carol');
      try {
        final message = await alice.core.messageService.sendText(
          recipient: bob.identity!.record,
          text: 'not for carol',
        );
        final bytes = (await alice.storedBundle(message.id)).bytes;
        expect(() => carol.open(bytes), throwsA(isA<ProtocolException>()));
      } finally {
        await carol.dispose();
      }
    });
  });

  group('PNG attachments', () {
    test('carries a PNG losslessly and preserves its bytes', () async {
      final png = buildPng(
        width: 4,
        height: 3,
        idat: List<int>.generate(4096, (i) => i & 0xFF),
      );
      final message = await alice.core.messageService.sendPng(
        recipient: bob.identity!.record,
        bytes: png,
        filename: 'holiday.png',
      );
      expect(message.payloadType, MessagePayloadType.png);
      expect(message.imageBytes, png);

      expect(
        await bob.core.messageService.handleIncoming(
          await bob.open((await alice.storedBundle(message.id)).bytes),
        ),
        MessageInboundOutcome.stored,
      );

      final received = (await bob.core.messages.find(message.id))!;
      expect(received.imageBytes, png);
      expect(received.imageWidth, 4);
      expect(received.imageHeight, 3);
      expect(received.imageContentHashHex, message.imageContentHashHex);
      expect(received.imageFilename, 'holiday.png');
    });

    test('rejects a PNG whose content hash does not match', () async {
      final png = buildPng();
      final now = alice.clock.now().millisecondsSinceEpoch;
      final bundleId = randomBytes(16);
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.message,
        bundleId: bundleId,
        payload: MessageFactory.buildPng(
          messageIdHex: bytesToHex(bundleId),
          createdAtMs: now,
          expiresAtMs: now + 600000,
          bytes: png,
          contentHashHex: 'deadbeef',
          width: 2,
          height: 2,
          filename: 'bad.png',
        ),
      );
      expect(
        await bob.core.messageService.handleIncoming(await bob.open(bytes)),
        MessageInboundOutcome.invalid,
      );
    });

    test('rejects a PNG whose dimensions do not match the payload', () async {
      final png = buildPng(width: 2, height: 2);
      final now = alice.clock.now().millisecondsSinceEpoch;
      final bundleId = randomBytes(16);
      final digest = (await PngValidator.validate(png)).contentHashHex;
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.message,
        bundleId: bundleId,
        payload: MessageFactory.buildPng(
          messageIdHex: bytesToHex(bundleId),
          createdAtMs: now,
          expiresAtMs: now + 600000,
          bytes: png,
          contentHashHex: digest,
          width: 99,
          height: 2,
          filename: 'bad.png',
        ),
      );
      expect(
        await bob.core.messageService.handleIncoming(await bob.open(bytes)),
        MessageInboundOutcome.invalid,
      );
    });

    test('rejects a non-PNG attachment', () async {
      expect(
        () => alice.core.messageService.sendPng(
          recipient: bob.identity!.record,
          bytes: Uint8List.fromList([1, 2, 3, 4]),
          filename: 'not.png',
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('Signed receipts', () {
    test('rejects a receipt with an invalid signature', () async {
      final message = await alice.core.messageService.sendText(
        recipient: bob.identity!.record,
        text: 'hi',
      );
      final now = bob.clock.now().millisecondsSinceEpoch;
      final bytes = await bob.sealFor(
        recipient: alice,
        type: EnvelopeType.deliveryReceipt,
        bundleId: randomBytes(16),
        expiresAtMs: now + 600000,
        payload: {
          'mid': message.id,
          'os': alice.id,
          'dby': bob.id,
          'at': now,
          'v': 1,
          'sig': randomBytes(64),
        },
      );
      expect(
        await alice.core.receiptService.handleIncoming(await alice.open(bytes)),
        ReceiptInboundResult.invalid,
      );
    });

    test('ignores a receipt signed by the wrong party', () async {
      final message = await alice.core.messageService.sendText(
        recipient: bob.identity!.record,
        text: 'hi',
      );
      final now = bob.clock.now().millisecondsSinceEpoch;
      // Signed by Bob, but claims Carol delivered it: must be ignored.
      final bytes = await bob.sealFor(
        recipient: alice,
        type: EnvelopeType.deliveryReceipt,
        bundleId: randomBytes(16),
        expiresAtMs: now + 600000,
        payload: {
          'mid': message.id,
          'os': alice.id,
          'dby': 'fid_00000000000000000000000000000000',
          'at': now,
          'v': 1,
          'sig': randomBytes(64),
        },
      );
      expect(
        await alice.core.receiptService.handleIncoming(await alice.open(bytes)),
        ReceiptInboundResult.ignored,
      );
    });

    test('reconciles a receipt that arrived before its message', () async {
      final messageId = bytesToHex(randomBytes(16));
      final now = bob.clock.now().millisecondsSinceEpoch;
      final incomingForBob = ChatMessage(
        id: messageId,
        senderId: alice.id,
        recipientId: bob.id,
        peerId: alice.id,
        direction: MessageDirection.incoming,
        status: MessageStatus.received,
        payloadType: MessagePayloadType.text,
        createdAtMs: now,
        expiresAtMs: now + 600000,
        text: 'early receipt',
        receivedAtMs: now,
      );
      await bob.core.receiptService.sendReceiptFor(
        message: incomingForBob,
        recipient: alice.identity!.record,
      );
      final receiptBundle = await firstBundleOfType(
        bob,
        EnvelopeType.deliveryReceipt,
      );

      expect(
        await alice.core.receiptService.handleIncoming(
          await alice.open(receiptBundle.bytes),
        ),
        ReceiptInboundResult.storedUnmatched,
      );

      await alice.core.messages.insertIfAbsent(
        ChatMessage(
          id: messageId,
          senderId: alice.id,
          recipientId: bob.id,
          peerId: bob.id,
          direction: MessageDirection.outgoing,
          status: MessageStatus.queued,
          payloadType: MessagePayloadType.text,
          createdAtMs: now,
          expiresAtMs: now + 600000,
          text: 'early receipt',
        ),
      );
      expect(await alice.core.receiptService.reconcile(), 1);
      expect(
        (await alice.core.messages.find(messageId))!.status,
        MessageStatus.delivered,
      );
    });
  });
}
