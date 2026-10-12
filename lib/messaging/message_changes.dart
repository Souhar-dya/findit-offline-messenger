import 'dart:async';

/// A coarse "messages changed" signal shared by the message and receipt
/// services.
///
/// Chat screens listen to it so a conversation refreshes the instant something
/// happens elsewhere in the pipeline — a message is sent, accepted, read, or
/// confirmed delivered by an inbound receipt. Without it the UI would only
/// reload when the user sent the *next* message, which made a message linger on
/// "Sending…" long after the peer had it.
class MessageChanges {
  final StreamController<void> _controller = StreamController<void>.broadcast();

  /// Emits whenever any message lifecycle event occurs. The payload is
  /// intentionally empty: listeners re-read the repository for the truth.
  Stream<void> get stream => _controller.stream;

  void notify() {
    if (!_controller.isClosed) _controller.add(null);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
