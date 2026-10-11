/// A source of the current time, injectable for deterministic tests.
abstract class Clock {
  DateTime now();
}

/// Wall-clock implementation used at runtime.
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// Manually controlled clock used in tests.
class FixedClock implements Clock {
  FixedClock(this._current);

  DateTime _current;

  @override
  DateTime now() => _current;

  /// Moves the clock forward by [duration].
  void advance(Duration duration) {
    _current = _current.add(duration);
  }

  /// Jumps the clock to an explicit instant.
  void setTo(DateTime instant) {
    _current = instant;
  }
}
