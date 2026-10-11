import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/errors/app_exception.dart';

/// Frame types carried by a [FrameStream]. This is transport-level framing
/// only: the payloads are opaque byte strings to the framing layer.
const int frameTypeHandshake = 1;
const int frameTypeSummary = 2;
const int frameTypeBundle = 3;

/// One decoded inbound frame.
class InboundFrame {
  const InboundFrame(this.type, this.payload);

  final int type;
  final Uint8List payload;
}

/// Length-prefixed, type-tagged framing over a duplex byte channel.
///
/// Wire format (per frame):
/// ```
/// [ 1 byte type ][ 4 byte big-endian length ][ payload ]
/// ```
/// The length field is bounded by [maxFrameBytes]; a frame that declares a
/// larger length closes the channel with a [TransportException] surfaced on
/// [errors] (defence in depth against a malicious or broken peer).
///
/// Writes are strictly sequential: [send] calls never interleave partial
/// frames. Reads are incremental, so TCP segmentation and coalescing are
/// handled transparently and a frame is only delivered once its full payload
/// has arrived.
class FrameStream {
  FrameStream(this._socket, {this.maxFrameBytes = _defaultMaxFrameBytes}) {
    _subscription = _socket.listen(
      _onChunk,
      onError: (Object error) => _fail('Receive error: $error', error),
      onDone: _onRemoteDone,
      cancelOnError: true,
    );
  }

  static const int _defaultMaxFrameBytes = 32 * 1024 * 1024;
  static const int _headerLength = 5;

  final Socket _socket;
  final int maxFrameBytes;

  final StreamController<InboundFrame> _frames =
      StreamController<InboundFrame>();
  final StreamController<Object> _errors = StreamController<Object>();

  Uint8List _buffer = Uint8List(0);
  int _used = 0;
  Future<void> _writeQueue = Future<void>.value();
  StreamSubscription<List<int>>? _subscription;
  bool _open = true;

  /// Decoded frames arriving from the remote end.
  Stream<InboundFrame> get frames => _frames.stream;

  /// Transport-level errors on this channel.
  Stream<Object> get errors => _errors.stream;

  bool get isOpen => _open;

  /// Sends one frame. Frames are serialized through a queue so they can never
  /// interleave on the wire.
  Future<void> send(int type, List<int> payload) {
    if (!_open) {
      return Future<void>.error(
        const TransportException('Connection is closed'),
      );
    }
    if (payload.length > maxFrameBytes) {
      return Future<void>.error(
        TransportException('Frame payload exceeds $maxFrameBytes bytes'),
      );
    }
    final frame = _encode(type, payload);
    final run = _swallow(_writeQueue).then((_) async {
      if (!_open) {
        throw const TransportException('Connection is closed');
      }
      _socket.add(frame);
      await _socket.flush();
    });
    _writeQueue = _swallow(run);
    return run;
  }

  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _subscription?.cancel();
    unawaited(_frames.close());
    unawaited(_errors.close());
    _socket.destroy();
  }

  static Uint8List _encode(int type, List<int> payload) {
    final out = Uint8List(_headerLength + payload.length);
    out[0] = type;
    final length = payload.length;
    out[1] = (length >> 24) & 0xff;
    out[2] = (length >> 16) & 0xff;
    out[3] = (length >> 8) & 0xff;
    out[4] = length & 0xff;
    out.setRange(_headerLength, out.length, payload);
    return out;
  }

  void _onChunk(List<int> chunk) {
    final needed = _used + chunk.length;
    if (_buffer.length < needed) {
      final next = Uint8List(needed);
      next.setRange(0, _used, _buffer);
      _buffer = next;
    }
    _buffer.setRange(_used, needed, chunk);
    _used = needed;
    _drain();
  }

  void _drain() {
    while (_used >= _headerLength) {
      final length =
          (_buffer[1] << 24) |
          (_buffer[2] << 16) |
          (_buffer[3] << 8) |
          (_buffer[4] & 0xff);
      if (length > maxFrameBytes) {
        _fail('Frame declares length $length above the $maxFrameBytes limit');
        return;
      }
      final total = _headerLength + length;
      if (_used < total) return;
      final payload = Uint8List(length);
      payload.setRange(0, length, _buffer, _headerLength);
      if (_open && !_frames.isClosed) {
        _frames.add(InboundFrame(_buffer[0], payload));
      }
      final remaining = _used - total;
      if (remaining > 0) {
        _buffer.setRange(0, remaining, _buffer, total);
      }
      _used = remaining;
    }
  }

  void _onRemoteDone() {
    if (!_open) return;
    _open = false;
    unawaited(_subscription?.cancel());
    unawaited(_frames.close());
    unawaited(_errors.close());
    _socket.destroy();
  }

  void _fail(String message, [Object? cause]) {
    if (!_open) return;
    _open = false;
    if (!_errors.isClosed) {
      _errors.add(TransportException(message, cause: cause));
    }
    unawaited(_subscription?.cancel());
    unawaited(_frames.close());
    unawaited(_errors.close());
    _socket.destroy();
  }

  /// Runs [future] and swallows its error so the write queue can never be
  /// poisoned; the error re-surfaces through the future returned by [send].
  static Future<void> _swallow(Future<void> future) async {
    try {
      await future;
    } catch (_) {
      // The caller observes the error on the chained future.
    }
  }
}
