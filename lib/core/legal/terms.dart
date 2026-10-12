import 'legal_section.dart';

/// The Acceptable Use Policy shown on the consent gate before any network
/// activity.
///
/// This is the on-device copy of docs/legal/ACCEPTABLE_USE_POLICY.md. It is
/// incorporated by reference into the End User License Agreement, which the
/// consent screen links to.
///
/// Bump [version] whenever the wording changes: the accepted version is stored
/// locally, and the app re-prompts for consent when the stored accepted version
/// differs from [version].
class TermsDocument {
  TermsDocument._();

  /// Version of the wording below. Bump it whenever the text changes.
  static const String version = '3.0';

  static const String title = 'Acceptable Use Policy';

  static const String intro =
      'These rules govern how you may use FindIt. They form part of, and are '
      'incorporated into, the End User License Agreement (EULA). Read them '
      'before you continue: by accepting, you agree to this Acceptable Use '
      'Policy and to the EULA. No data is transferred until you accept.';

  static const List<LegalSection> sections = <LegalSection>[
    LegalSection(
      'Prohibited conduct',
      'You may not use FindIt to: 1. send or transmit anything unlawful, or '
          'use the App to break the law; 2. send content that infringes another '
          'person\'s copyright, trademark, or other intellectual-property '
          'rights; 3. threaten, harass, defame, bully, or target other users, '
          'or send hateful or violent content; 4. send unsolicited bulk '
          'messages, phishing attempts, or deceptive content; 5. bypass '
          'authentication, or probe, scan, or breach the App\'s security or '
          'access controls; 6. scrape, crawl, or harvest data from the App '
          'except as expressly permitted; 7. decompile, disassemble, or '
          'reverse-engineer the App, except where applicable law forbids this '
          'restriction; or 8. overload, disrupt, or interfere with the App or '
          'other users (for example denial-of-service attacks or excessive '
          'load).',
    ),
    LegalSection(
      'What the developer can and cannot do',
      'FindIt is a decentralized, peer-to-peer application. The developer does '
          'not operate servers, does not store your content, and cannot access '
          'or remove content from another user\'s device. Once content is '
          'delivered to another user\'s device, the developer has no ability to '
          'delete, modify, or retract it, so enforcement is limited to actions '
          'within the developer\'s own control.\n\n'
          'Can do: terminate or suspend a user\'s licence to use the App; issue '
          'updates that change or restrict its behaviour; refuse to relay '
          'content for specific users when the developer\'s own device is '
          'acting as a relay; report illegal activity to law-enforcement '
          'authorities.\n\n'
          'Cannot do: remove content from another user\'s device; prevent '
          'direct communication between other users; monitor or censor the '
          'content of messages (they are end-to-end encrypted); retract '
          'messages already delivered.\n\n'
          'By using the App you acknowledge these limitations and agree that '
          'the developer is not responsible for content transmitted between '
          'other users, and does not moderate, curate, or verify it.',
    ),
    LegalSection(
      'Copyright complaints (DMCA)',
      'The developer responds to notices of alleged copyright infringement '
          'under the DMCA. Send a notice to the designated agent, Souhardya '
          'Kundu, at kundusouhardya@gmail.com. The notice must include: (1) a '
          'physical or electronic signature of the copyright owner or an '
          'authorised agent; (2) identification of the copyrighted work '
          'claimed to be infringed; (3) identification of the infringing '
          'material (for example a description of the content and the user '
          'identifier or handle associated with it); (4) your contact '
          'information; (5) a statement of good-faith belief that the use is '
          'unauthorised; and (6) a statement, under penalty of perjury, that '
          'the notice is accurate and that you are authorised to act.\n\n'
          'Because the App is decentralized and does not host content, the '
          'developer cannot remove infringing material from other users\' '
          'devices. On a valid notice the developer will investigate the '
          'claim, take reasonable steps within its control (such as '
          'terminating the licence of a user who repeatedly infringes), and '
          'report the activity to the appropriate authorities where '
          'appropriate.',
    ),
    LegalSection(
      'Enforcement',
      'Violating this Policy is a breach of the EULA. The developer may '
          'suspend or terminate your licence to use the App, with or without '
          'notice depending on severity, and may report illegal activity to '
          'law-enforcement authorities. The developer does not and cannot '
          'remove content from other users\' devices.',
    ),
    LegalSection(
      'Reporting violations',
      'To report a violation of this Policy, contact '
          'kundusouhardya@gmail.com.',
    ),
  ];
}
