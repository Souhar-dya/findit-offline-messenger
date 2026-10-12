/// A heading + body pair used by the in-app legal documents: the Acceptable
/// Use Policy shown on the consent gate, and the End User License Agreement it
/// links to.
///
/// The on-device copies mirror docs/legal/ACCEPTABLE_USE_POLICY.md and
/// docs/legal/EULA.md so the terms can be read without a network connection.
class LegalSection {
  const LegalSection(this.heading, this.body);

  final String heading;
  final String body;
}
