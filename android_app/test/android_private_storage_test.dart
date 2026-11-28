import 'package:flutter_test/flutter_test.dart';
import 'package:spicychat_qol_app/services/android_private_storage.dart';

void main() {
  const bot = '12345678-1234-1234-1234-123456789abc';
  const conversation = 'abcdef12-1234-1234-1234-123456789abc';
  const message = {'characterId': bot, 'conversationId': conversation};
  test('matches only exact trusted saved conversation', () {
    expect(AndroidPrivateStorage.matchesChat(Uri.parse('https://spicychat.ai/chat/$bot/$conversation'), message), isTrue);
    expect(AndroidPrivateStorage.matchesChat(Uri.parse('https://www.spicychat.ai/en/chat/$bot/$conversation?foo=bar'), message), isTrue);
    for (final url in [
      'https://spicychat.ai/chat/$bot',
      'https://spicychat.ai/chat/$bot/$bot',
      'https://spicychat.ai/chat/$bot/$conversation/extra',
      'http://spicychat.ai/chat/$bot/$conversation',
      'https://spicychat.ai.evil.test/chat/$bot/$conversation',
      'https://spicychat.ai:8443/chat/$bot/$conversation',
      'https://user@spicychat.ai/chat/$bot/$conversation',
    ]) {
      expect(AndroidPrivateStorage.matchesChat(Uri.parse(url), message), isFalse);
    }
  });
  test('unknown QoL versions and invalid settings action fail before native request', () async {
    final incompatible = await AndroidPrivateStorage.request({'type': 'DS_GENERATION_QUOTA_RESEARCH'}, url: 'https://spicychat.ai', version: '0.3.4');
    expect(incompatible, contains('requires reviewed QoL'));
    final invalid = await AndroidPrivateStorage.request({'type': 'DS_GENERATION_QUOTA_RESEARCH'}, url: '', version: '0.3.3', settings: true);
    expect(invalid, contains('Invalid Settings operation'));
  });
}
