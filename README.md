# SVOI — VPN-клиент для Windows

<img src="assets/brand/svoi-avatar-amber.png" alt="SVOI" width="96">

Независимый клиент на Flutter / Dart с движком Go / Xray. Текущая версия — **0.5.0-prebeta.6**. Использует ваши подписки; VPN-серверы в комплект не входят. Android и iOS пока не выпускаются.

## Скачать

- [Установщик Windows x64](https://github.com/1atex/svoi/releases/download/v0.5.0-prebeta.6/SVOI-Flutter-0.5.0-prebeta.6-windows-x64-setup.exe)
- [Portable ZIP](https://github.com/1atex/svoi/releases/download/v0.5.0-prebeta.6/SVOI-Flutter-0.5.0-prebeta.6-windows-x64.zip) — распакуйте весь архив, запускайте `svoi_flutter.exe`.
- [Все релизы](https://github.com/1atex/svoi/releases)

Установщик включает Xray, Wintun и необходимые библиотеки, создаёт ярлыки и предлагает запуск после установки. Для TUN и zapret отметьте «Всегда запускать от имени администратора»: Windows запросит подтверждение UAC при запуске. WebView2 не требуется.

## Возможности

- Несколько подписок, импорт ссылкой / текстом / файлом, обновление при входе.
- Xray JSON с маршрутизацией и балансировщиками, VLESS, VMess, Trojan, Shadowsocks и другие поддерживаемые форматы.
- TUN, системный и локальный прокси; правила TUN для выбранных приложений.
- Поиск серверов, флаги, избранное, последний запуск, параллельные HTTPS-проверки и просмотр конфигураций.
- Передача профиля кодом или файлом с предпросмотром импорта.
- zapret: загрузка релизов Flowseal, обновления, стратегии, проверки сайтов, DPI-checkers, диагностика Windows, отчёты и журнал.
- Обновления SVOI внутри приложения: скачивание, проверка SHA-256 и установка по команде пользователя.

Это prebeta. Ошибка контрольного HTTPS-запроса не всегда означает неисправность VPN. Совместимость TUN с zapret зависит от стратегии и сети; kill switch отсутствует. Передача профиля не отменяет серверные ограничения провайдера.

## Обновления и перенос

В «Настройках» доступны проверка обновлений и автоматическое скачивание. SVOI получает Flutter-установщики из GitHub Releases; заходить на страницу GitHub для каждого обновления не требуется. Перед установкой соединения останавливаются, приложение закрывается.

Первый переход с WebView-клиента выполняется установщиком Flutter. Перенесите профиль кодом или файлом: данные Flutter хранятся отдельно в `%APPDATA%/SVOI-Flutter`. Не публикуйте эту папку и коды переноса — они содержат доступ к подпискам. Следующие Flutter-релизы обновляются через приложение. Prebeta принимает prerelease-версии; стабильный канал пропускает их.

## Разработка

- [Flutter: сборка, тесты и архитектура](flutter_client/README.md)
- [Примечания к релизу](flutter_client/RELEASE-NOTES.md)
- [Прежний WebView-клиент](docs/WEBVIEW.md)
- [Измерения производительности](PERFORMANCE.md)

Нужны Go, Flutter 3.47.7, Visual Studio с C++ Desktop workload и Inno Setup 6:

```powershell
./prepare-core.ps1
./flutter_client/build-prototype.ps1 -FlutterSdk C:/path/to/flutter
```

Скрипт проверяет исходники и собирает приложение, ZIP, установщик и SHA-256 в `releases/flutter-v<версия>/`. SDK, пользовательские данные и сборки исключены из Git.

## Выпуск обновления

1. Обновите `nativeVersion` в `main.go`, версию в `flutter_client/pubspec.yaml`, `clientVersion` в `flutter_client/lib/features.dart`, версию сборочного скрипта и release notes.
2. Выполните проверки и соберите пакет локально.
3. Отправьте коммит и тег `v<версия>` в GitHub.

Workflow `.github/workflows/release.yml` проверит версии, скачает закреплённые SDK и Xray с проверкой SHA-256, выполнит тесты и опубликует установщик, ZIP и контрольные суммы. Версии с суффиксом prebeta публикуются как prerelease. Дождитесь успешного workflow перед объявлением релиза. Клиенты принимают установщик своего канала и проверяют его digest из GitHub API.

Иконки экспортируются из исходной аватарки: `python assets/brand/export-icons.py` (Pillow).

## Лицензия

SVOI — [MIT](LICENSE). Лицензии Xray, Wintun, Flutter и зависимостей включены в дистрибутив. Код INCY не используется.
