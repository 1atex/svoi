import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/countries.dart';
import 'package:svoi_flutter/controller.dart';

void main() {
  test(
    'country prefixes, emoji and names resolve without guessing IP location',
    () {
      for (final name in [
        'nl Автоматический',
        '[NL] Автоматический',
        '(nl) Автоматический',
        '🇳🇱 Автоматический',
      ]) {
        final country = ServerCountry.parse(name);
        expect(country.code, 'NL', reason: name);
        expect(country.title, 'Автоматический');
      }
      expect(ServerCountry.parse('nl').title, 'Нидерланды');
      expect(ServerCountry.parse('UK London').code, 'GB');
      expect(ServerCountry.parse('Finland').code, 'FI');
      expect(ServerCountry.parse('сервер · Германия · 02').code, 'DE');
      expect(ServerCountry.parse('DEMO proxy').code, isNull);
      expect(ServerCountry.parse('Unknown').code, isNull);
      expect(
        ServerCountry.parse('[ZZ] Автоматический').title,
        '[ZZ] Автоматический',
      );
      expect(ServerCountry.parse('🇫🇷 Париж', countryCode: 'NL').code, 'NL');
    },
  );

  test('search includes country names for abbreviated server labels', () {
    final server = ServerEntry({
      'id': '1',
      'name': 'nl Auto',
      'protocol': 'vless',
    });
    expect(server.search, contains('нидерланды'));
    expect(server.country.title, 'Auto');
  });
}
