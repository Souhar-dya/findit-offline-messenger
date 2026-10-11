/// The consent / terms document shown before any network activity.
///
/// Bump [version] whenever the wording changes: the accepted version is stored
/// locally, and the app re-prompts for consent when the stored accepted version
/// differs from [version].
class TermsDocument {
  TermsDocument._();

  /// Version of the wording below. Bump it whenever the text changes.
  static const String version = '1.2';

  static const String title = 'Consent & terms of use';

  static const String intro =
      'FindIt is an offline-first messenger. Please read this before you '
      'continue. It explains what leaves your device and what your device is '
      'allowed to do. No data is transferred until you agree.';

  static const List<TermsSection> sections = <TermsSection>[
    TermsSection(
      'What FindIt is',
      'FindIt works without an account, a server or an internet connection. '
          'Your identity is a key pair created on this device. The private '
          'keys live in the platform secure storage (Keystore / Keychain) and '
          'are never exported.',
    ),
    TermsSection(
      'What leaves your device',
      'Only two things ever leave this device: your signed public identity '
          'record, and end-to-end encrypted bundles addressed to other people. '
          'Private keys never leave secure storage.',
    ),
    TermsSection(
      'One switch: radio silent until you turn it on',
      'There is a single master switch, and it is off by default. While it is '
          'off the device is radio silent: it does not discover nearby devices, '
          'and it sends and receives nothing — your own messages stay on the '
          'device and nothing is carried for anyone else. Turn the switch on to '
          'start: the device discovers nearby peers, sends and receives your own '
          'messages, and may also carry other people\'s encrypted bundles while '
          'it is nearby. Turn it off at any time to stop; third-party bundles '
          'stored for others are then deleted.',
    ),
    TermsSection(
      'What a relay can see',
      'A relay cannot read message content, but it can observe metadata such '
          'as approximate time, size and hop path. While the switch is on, that '
          'metadata may pass through your device.',
    ),
    TermsSection(
      'Limits and no guarantees',
      'Delivery is best-effort and never guaranteed. Messages expire 24 hours '
          'after they are created and expiry is never extended by relaying. '
          'Android and iOS may suspend the app, so always-on networking is not '
          'promised.',
    ),
    TermsSection(
      'Prototype, not a product',
      'FindIt is an unaudited protocol and UX prototype. Do not rely on it for '
          'anything safety-critical, and treat it as a work in progress.',
    ),
  ];
}

/// One heading + body pair in the terms document.
class TermsSection {
  const TermsSection(this.heading, this.body);

  final String heading;
  final String body;
}
