import 'package:country_flags/country_flags.dart';

class ServerCountry {
  const ServerCountry(this.code, this.title);
  final String? code;
  final String title;
  String get label => names[code]?.first ?? code ?? 'Страна не указана';

  static const names = <String, List<String>>{
    'NL': ['Нидерланды', 'Netherlands', 'Holland'],
    'DE': ['Германия', 'Germany', 'Deutschland'],
    'FI': ['Финляндия', 'Finland'],
    'FR': ['Франция', 'France'],
    'GB': ['Великобритания', 'United Kingdom', 'Britain'],
    'US': ['США', 'United States', 'USA'],
    'RU': ['Россия', 'Russia'],
    'TR': ['Турция', 'Turkey', 'Türkiye'],
    'SE': ['Швеция', 'Sweden'],
    'CH': ['Швейцария', 'Switzerland'],
    'PL': ['Польша', 'Poland'],
    'LV': ['Латвия', 'Latvia'],
    'LT': ['Литва', 'Lithuania'],
    'EE': ['Эстония', 'Estonia'],
    'KZ': ['Казахстан', 'Kazakhstan'],
    'UA': ['Украина', 'Ukraine'],
    'CA': ['Канада', 'Canada'],
    'JP': ['Япония', 'Japan'],
    'SG': ['Сингапур', 'Singapore'],
    'HK': ['Гонконг', 'Hong Kong'],
    'AU': ['Австралия', 'Australia'],
    'AT': ['Австрия', 'Austria'],
    'CZ': ['Чехия', 'Czechia', 'Czech Republic'],
    'ES': ['Испания', 'Spain'],
    'IT': ['Италия', 'Italy'],
    'NO': ['Норвегия', 'Norway'],
    'AE': ['ОАЭ', 'United Arab Emirates'],
    'IL': ['Израиль', 'Israel'],
    'AM': ['Армения', 'Armenia'],
    'GE': ['Грузия', 'Georgia'],
  };
  static final _emoji = RegExp(r'[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true);
  static final _prefix = RegExp(
    r'^(?:\[([a-z]{2})\]|\(([a-z]{2})\)|([a-z]{2})(?=$|[^a-z]))[\s|:·\-–—]*',
    caseSensitive: false,
  );
  static String? _valid(String? value) {
    var code = value?.trim().toUpperCase();
    if (code == 'UK') code = 'GB';
    return code != null && FlagCode.fromCountryCode(code) != null ? code : null;
  }

  factory ServerCountry.parse(String name, {String? countryCode}) {
    final text = name.trim();
    final emoji = _emoji.firstMatch(text);
    final prefix = _prefix.firstMatch(text);
    final embedded = emoji == null
        ? _valid(prefix?.group(1) ?? prefix?.group(2) ?? prefix?.group(3))
        : _valid(
            String.fromCharCodes(
              emoji.group(0)!.runes.map((r) => r - 0x1f1e6 + 65),
            ),
          );
    var code = _valid(countryCode) ?? embedded;
    var title = text;
    if (embedded != null && code == embedded) {
      title = text
          .replaceFirst(emoji?.group(0) ?? prefix!.group(0)!, '')
          .trim();
    }
    if (code == null) {
      for (final entry in names.entries) {
        if (entry.value.any(
          (alias) => RegExp(
            '(^|[^a-zа-яё])${RegExp.escape(alias)}(\$|[^a-zа-яё])',
            caseSensitive: false,
          ).hasMatch(text),
        )) {
          code = entry.key;
          break;
        }
      }
    }
    return ServerCountry(
      code,
      title.isEmpty ? names[code]?.first ?? code ?? name : title,
    );
  }
}
