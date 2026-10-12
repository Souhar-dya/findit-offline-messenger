import 'legal_section.dart';

/// The End User License Agreement, read in full from the consent screen.
///
/// This is the on-device copy of docs/legal/EULA.md, so the licence can be read
/// without a network connection. The Acceptable Use Policy is incorporated by
/// reference and is shown on the consent gate itself.
class EulaDocument {
  EulaDocument._();

  static const String title = 'End User License Agreement';

  static const String subtitle = 'Last updated 2026-10-12';

  static const String intro =
      'This End User License Agreement ("Agreement") is a legal agreement '
      'between you ("User") and Souhardya Kundu ("Licensor") for the FindIt '
      'application ("App"). By installing or using the App you agree to the '
      'terms of this Agreement. This Agreement incorporates the Acceptable Use '
      'Policy by reference.';

  static const List<LegalSection> sections = <LegalSection>[
    LegalSection(
      '1. Definitions',
      '"App" means the FindIt application, including all code, documentation, '
          'and updates. "User" means the person who installs or uses the App. '
          '"Content" means messages, images, and other data the User sends or '
          'receives through the App. "Licensor" means Souhardya Kundu, the '
          'individual who distributes the App.',
    ),
    LegalSection(
      '2. License grant',
      'Subject to this Agreement, the Licensor grants the User a limited, '
          'non-exclusive, non-transferable, non-sublicensable right '
          'to install and use one copy of the App on a mobile device the User '
          'owns or controls.\n\n'
          'The User may not: resell, rent, lease, or redistribute the App; '
          'copy, modify, or create derivative works of the App; or remove or '
          'alter any proprietary notices in the App.',
    ),
    LegalSection(
      '3. User content',
      'The User retains ownership of Content the User sends or receives '
          'through the App ("Your Content"). The User grants the Licensor a '
          'worldwide, non-exclusive, royalty-free licence to store, process, '
          'and transmit Your Content solely to operate the App and deliver '
          'messages to their intended recipients. This licence ends when the '
          'User deletes the Content or stops using the App, except for Content '
          'already delivered to other users.',
    ),
    LegalSection(
      '4. Decentralized architecture and no operator control',
      'The App is a decentralized, peer-to-peer application. The Licensor does '
          'not operate servers, does not store User Content, and has no ability '
          'to monitor, censor, or remove Content transmitted between Users. '
          'Once Content is delivered to another User\'s device, the Licensor '
          'cannot access, modify, or retract it.\n\n'
          'Because of this architecture, the Licensor has no control over what '
          'Users transmit through the App and bears no responsibility for '
          'Content exchanged between Users. By using the App, the User '
          'acknowledges and accepts this limitation.',
    ),
    LegalSection(
      '5. Updates',
      'The App may be updated. Updates are optional and may be installed '
          'automatically depending on the User\'s device settings. This '
          'Agreement applies to all updates.',
    ),
    LegalSection(
      '6. Warranty disclaimer',
      'THE APP IS PROVIDED "AS IS" AND "AS AVAILABLE," WITHOUT WARRANTIES OF '
          'ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE '
          'IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR '
          'PURPOSE, AND NON-INFRINGEMENT. THE LICENSOR DOES NOT WARRANT THAT '
          'THE APP WILL BE UNINTERRUPTED, ERROR-FREE, OR SECURE.',
    ),
    LegalSection(
      '7. Limitation of liability',
      'TO THE FULLEST EXTENT PERMITTED BY LAW, THE LICENSOR\'S TOTAL '
          'AGGREGATE LIABILITY ARISING OUT OF OR RELATING TO THIS AGREEMENT OR '
          'THE APP WILL NOT EXCEED THE GREATER OF (A) THE FEES PAID BY THE USER '
          'TO THE LICENSOR IN THE 12 MONTHS BEFORE THE EVENT GIVING RISE TO '
          'THE CLAIM, OR (B) \$10. THE LICENSOR WILL NOT BE LIABLE FOR ANY '
          'INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES, '
          'OR FOR LOST PROFITS OR DATA.\n\n'
          'This limitation does not apply to liability for gross negligence, '
          'willful misconduct, bodily injury, or fraud, or to any liability '
          'that cannot be limited under applicable law. The Licensor is not '
          'responsible for the conduct of any User, including Content '
          'transmitted between Users, and has no ability to monitor, censor, '
          'or remove such Content.',
    ),
    LegalSection(
      '8. Indemnity',
      'The User agrees to indemnify and hold harmless the Licensor from any '
          'claims, damages, and expenses (including reasonable attorney fees) '
          'arising from the User\'s Content or the User\'s breach of this '
          'Agreement.',
    ),
    LegalSection(
      '9. Termination',
      'The App runs only on the User\'s own device and is openly '
          'downloadable, so the Licensor cannot and does not remotely revoke '
          'or disable a copy the User has already installed. This Agreement '
          'and the licence it grants end when the User stops using the App and '
          'deletes it. The User may stop using the App at any time. Sections '
          'that by their nature should survive (warranty disclaimer, '
          'limitation of liability, indemnity, governing law, modification, '
          'and severability) survive termination.',
    ),
    LegalSection(
      '10. Governing law and venue',
      'This Agreement is governed by the laws of India, without regard to its '
          'conflict-of-laws rules. The exclusive venue for any dispute is the '
          'courts located in Bangalore, Karnataka, India, and the User consents '
          'to their personal jurisdiction.',
    ),
    LegalSection(
      '11. Modification',
      'The Licensor may update this Agreement. For material changes, the '
          'Licensor will give notice by in-app notice or email at least 30 days '
          'before the change takes effect and will ask the User to accept the '
          'updated Agreement. The User\'s continued use of the App after the '
          'effective date means the User accepts the updated Agreement for '
          'non-material changes.',
    ),
    LegalSection(
      '12. Severability',
      'If any provision of this Agreement is held unenforceable, that provision '
          'will be limited or removed to the minimum extent necessary, and the '
          'remaining provisions will stay in full force.',
    ),
    LegalSection(
      '13. Entire agreement',
      'This Agreement, together with the Acceptable Use Policy (incorporated by '
          'reference), is the entire agreement between the User and the '
          'Licensor regarding the App and supersedes any prior agreements or '
          'understandings.',
    ),
    LegalSection(
      '14. Contact',
      'For questions about this Agreement, contact the Licensor at '
          'kundusouhardya@gmail.com.',
    ),
  ];
}
