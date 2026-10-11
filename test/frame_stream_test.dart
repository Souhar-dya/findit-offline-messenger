import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:findit/core/errors/app_exception.dart';
import 'package:findit/core/utils/bytes.dart';
import 'package:findit/transport/frame_stream.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens a loopback socket pair, each wrapped in a [FrameStream].
Future<(FrameStream, FrameStream)> openPair({
  int maxFrameBytes = 32 * 1024 * 1024,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final clientFuture = Socket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
    timeout: const Duration(seconds: 10),
  );
  final peer = await server.first;
  final local = await clientFuture;
  await server.close();
  return (
    FrameStream(local, maxFrameBytes: maxFrameBytes),
    FrameStream(peer, maxFrameBytes: maxFrameBytes),
  );
}

/// Manually builds a frame (raw wire bytes) with [type] and [payload].
Uint8List craftFrame(int type, List<int> payload) {
  final frame = Uint8List(5 + payload.length);
  frame[0] = type;
  final length = payload.length;
  frame[1] = (length >> 24) & 0xff;
  frame[2] = (length >> 16) & 0xff;
  frame[3] = (length >> 8) & 0xff;
  frame[4] = length & 0xff;
  frame.setRange(5, frame.length, payload);
  return frame;
}

void main() {
  group('FrameStream', () {
    test('round-trips typed frames in order', () async {
      final (a, b) = await openPair();
      final received = <InboundFrame>[];
      final done = Completer<void>();
      final sub = b.frames.listen((frame) {
        received.add(frame);
        if (received.length == 3) done.complete();
      });

      await a.send(frameTypeHandshake, const [1, 2, 3]);
      await a.send(frameTypeSummary, const [4, 5]);
      await a.send(
        frameTypeBundle,
        Uint8List.fromList(List<int>.generate(100, (i) => i)),
      );
      await done.future.timeout(const Duration(seconds: 10));
      await sub.cancel();
      await a.close();
      await b.close();

      expect(received[0].type, frameTypeHandshake);
      expect(received[0].payload, [1, 2, 3]);
      expect(received[1].type, frameTypeSummary);
      expect(received[1].payload, [4, 5]);
      expect(received[2].type, frameTypeBundle);
      expect(received[2].payload.length, 100);
    });

    test('reassembles a frame split across arbitrary byte chunks', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientFuture = Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
        timeout: const Duration(seconds: 10),
      );
      final peer = await server.first;
      final client = await clientFuture;
      await server.close();

      final reader = FrameStream(peer);
      final payload = Uint8List.fromList(
        List<int>.generate(977, (i) => i % 251),
      );
      final received = Completer<InboundFrame>();
      reader.frames.listen((frame) {
        if (!received.isCompleted) received.complete(frame);
      });

      final frame = craftFrame(frameTypeBundle, payload);
      // Deliver the frame one byte at a time, flushing after every byte.
      for (final byte in frame) {
        client.add([byte]);
        await client.flush();
      }
      final decoded = await received.future.timeout(
        const Duration(seconds: 10),
      );
      await reader.close();
      client.destroy();
      peer.destroy();

      expect(decoded.type, frameTypeBundle);
      expect(decoded.payload, payload);
    });

    test('serializes concurrent sends so frames never interleave', () async {
      final (a, b) = await openPair();
      final received = <InboundFrame>[];
      final done = Completer<void>();
      final sub = b.frames.listen((frame) {
        received.add(frame);
        if (received.length == 2) done.complete();
      });
      final first = Uint8List.fromList(
        List<int>.generate(4000, (i) => i % 256),
      );
      final second = Uint8List.fromList(
        List<int>.generate(4000, (i) => (i + 128) % 256),
      );
      await Future.wait([
        a.send(frameTypeBundle, first),
        a.send(frameTypeBundle, second),
      ]);
      await done.future.timeout(const Duration(seconds: 10));
      await sub.cancel();
      await a.close();
      await b.close();

      expect(received.length, 2);
      final payloads = {
        for (final frame in received) bytesToHex(frame.payload),
      };
      expect(payloads, contains(bytesToHex(first)));
      expect(payloads, contains(bytesToHex(second)));
    });

    test('errors when a frame declares an oversized length', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientFuture = Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
        timeout: const Duration(seconds: 10),
      );
      final peer = await server.first;
      final client = await clientFuture;
      await server.close();

      final reader = FrameStream(peer, maxFrameBytes: 16);
      addTearDown(() async {
        await reader.close();
        client.destroy();
        peer.destroy();
      });

      final error = reader.errors.first;
      // A length far above the limit is enough for the reader to reject the
      // header; the payload itself is never required.
      client.add(craftFrame(frameTypeBundle, List<int>.filled(64, 0)));
      await client.flush();

      expect(await error, isA<TransportException>());
      expect(reader.isOpen, isFalse);
    });

    test('rejects sending after the channel is closed', () async {
      final (a, b) = await openPair();
      await a.close();
      await expectLater(
        a.send(frameTypeBundle, const []),
        throwsA(isA<TransportException>()),
      );
      await b.close();
    });

    test('delivers done when the remote closes', () async {
      final (a, b) = await openPair();
      final done = Completer<void>();
      b.frames.listen((_) {}, onDone: done.complete);
      await a.close();
      await done.future.timeout(const Duration(seconds: 10));
      expect(b.isOpen, isFalse);
      await b.close();
    });
  });
}
