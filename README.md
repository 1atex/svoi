<p align="center">
  <img src="docs/assets/hero.png" alt="SVOI — На своих условиях. VPN-клиент для Windows" width="100%">
</p>

<p align="center">
  <a href="https://github.com/1atex/svoi/releases/latest"><img src="https://img.shields.io/github/v/release/1atex/svoi?style=flat-square&label=release&color=e7b96a&labelColor=19191e" alt="Последний релиз"></a>
  <img src="https://img.shields.io/badge/Windows-x64-e7b96a?style=flat-square&labelColor=19191e" alt="Windows x64">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-e7b96a?style=flat-square&labelColor=19191e" alt="Лицензия MIT"></a>
  <img src="https://img.shields.io/badge/Flutter-Dart-e7b96a?style=flat-square&labelColor=19191e" alt="Flutter">
  <img src="https://img.shields.io/badge/Go-Xray-e7b96a?style=flat-square&labelColor=19191e" alt="Go и Xray">
</p>

<p align="center">
  <b>Ваши подписки. Ваши маршруты. Одно приложение.</b><br>
  Клиент на Flutter / Dart с движком Go / Xray и открытым исходным кодом.
</p>

<p align="center">
  <a href="https://github.com/1atex/svoi/releases/download/v0.6.0-beta.4/SVOI-0.6.0-beta.4-windows-x64-setup.exe"><b>↓ Скачать для Windows</b></a>
  &nbsp; · &nbsp;
  <a href="https://github.com/1atex/svoi/releases/download/android-v0.1.0-preview.8/SVOI-Android-0.1.0-preview.8-arm64.apk"><b>↓ Android APK · Preview</b></a>
  &nbsp; · &nbsp;
  <a href="https://github.com/1atex/svoi/releases/tag/linux-v0.6.0-preview.2"><b>↓ Linux · Preview</b></a>
  &nbsp; · &nbsp;
  <a href="https://github.com/1atex/svoi/releases/latest">Последний релиз Windows</a>
  &nbsp; · &nbsp;
  <a href="https://svoi.space/">Сайт SVOI</a>
  &nbsp; · &nbsp;
  <a href="https://svoi.space/changelog/">История обновлений</a>
  &nbsp; · &nbsp;
  <a href="https://github.com/1atex/svoi/issues">Сообщить об ошибке</a>
  &nbsp; · &nbsp;
  <a href="https://t.me/SVOI_client">Telegram · новости и обсуждения</a>
</p>

---

## Подключение без лишних экранов

Выберите сервер слева и подключитесь справа. В небольшом окне управление закреплено снизу. Подписки, избранное и проверка задержки доступны на одном экране; смена работающего сервера применяется кнопкой «Переключиться».

<img src="docs/assets/overview.png" alt="Главный экран SVOI: кнопка подключения, режим TUN и подписки" width="100%">

<sub>Интерфейс 0.5.0-beta.8 с демонстрационными профилями и задержками; реальные подключения и замеры на этих кадрах не выполнялись.</sub>

## Всё необходимое — внутри

| Подключения | Управление |
| :--- | :--- |
| **Несколько подписок** — импорт по ссылке, из текста или файла. Обновление при запуске. | **Серверы под рукой** — страны, поиск, избранное, сортировка по задержке. |
| **Три режима** — TUN, системный прокси и локальный прокси для ручной настройки. | **Проверка связи** — параллельные проверки через профиль, настраиваемые URL и тайм-аут. Время подготовки ядра учитывается отдельно. |
| **Маршруты из конфигурации** — полные Xray JSON-профили с правилами и балансировщиками. | **Просмотр JSON** — исходная конфигурация и конфигурация, подготовленная для подключения. |
| **Трафик выбранных приложений** — включения и исключения для TUN. | **Перенос профиля** — кодом или файлом, с предпросмотром перед импортом. |
| **zapret в интерфейсе** — загрузка и обновление релизов Flowseal, стратегии и проверки. | **Обновления SVOI** — проверка, скачивание, SHA-256 и запуск установки из приложения. |

**Оформление:** восемь тем — классика, светлая, системная, океан, изумруд, роза, AMOLED и Хэллоуин с кнопкой-тыквой. Выбор сохраняется на устройстве; смена темы не отключает VPN.

**Протоколы:** VLESS · VMess · Trojan · Shadowsocks · Hysteria2 (Windows с beta.11, Android с Preview 7). Также поддерживается импорт полных профилей Xray; доступность конкретного транспорта зависит от конфигурации и версии ядра.

Hysteria2: ссылки `hy2://` и `hysteria2://`, TLS, Salamander и переключение портов. Текущий Xray не поддерживает `insecure=1`; ссылки с `pinSHA256`, Gecko, Realm и неподдерживаемыми расширениями отклоняются при импорте с объяснением. Полные Xray JSON-профили позволяют задавать дополнительные параметры ядра.

<table>
  <tr>
    <td width="50%"><img src="docs/assets/servers.png" alt="Компактный экран с закреплённым подключением"><br><b>Управление всегда на виду</b></td>
    <td width="50%"><img src="docs/assets/applications.png" alt="Выбор приложений для TUN"><br><b>Решайте, какой трафик подключать</b></td>
  </tr>
</table>

<details>
<summary><b>Ещё скриншоты: zapret, обновления и выбор сервера</b></summary>

### zapret

<img src="docs/assets/zapret.png" alt="Управление zapret из SVOI" width="100%">

### Автоматизация и обновления

<img src="docs/assets/settings.png" alt="Обновление подписок и приложения" width="100%">

### Быстрое переключение

<img src="docs/assets/selector.png" alt="Окно выбора сервера" width="100%">

</details>

## Первый запуск

1. **Установите SVOI.** [Установщик Windows x64](https://github.com/1atex/svoi/releases/download/v0.6.0-beta.4/SVOI-0.6.0-beta.4-windows-x64-setup.exe) уже содержит Xray, Wintun и необходимые библиотеки. WebView2 не нужен.
2. **Добавьте свою подписку.** Вставьте ссылку или импортируйте конфигурацию из файла / текста.
3. **Выберите сервер и подключитесь.** На новой установке выбран TUN («Все приложения»); для него нужны права администратора. Сохранённый выбор режима при обновлении не меняется.

Предпочитаете без установки? [Скачайте portable ZIP](https://github.com/1atex/svoi/releases/download/v0.6.0-beta.4/SVOI-0.6.0-beta.4-windows-x64.zip), распакуйте **весь архив** и запустите `svoi.exe`.

Установщик предлагает запуск после установки. Ярлык на рабочем столе и запуск от имени администратора включены по умолчанию; флажки можно снять. При запуске с повышенными правами Windows покажет запрос UAC.

## Автозапуск Windows

В **Настройки → Автоматизация** включите запуск SVOI при входе в Windows и, при необходимости, последней выбранной стратегии zapret. Приложение запустится в трее; VPN подключается вручную. Настройка требует прав администратора и создаёт задачу только для текущего пользователя. Для zapret предварительно выберите стратегию на его странице.

## Обновляйтесь из приложения

В **Настройках** можно включить проверку релизов и автоматическое скачивание. Когда обновление готово, запустите установку из SVOI — заходить на GitHub каждый раз не требуется. Перед установкой приложение останавливает соединения и закрывается.

<details>
<summary><b>Перенос с прежнего WebView-клиента</b></summary>

В beta.4 рабочие данные находятся в `%APPDATA%/SVOI`. Данные beta.3 и более ранних версий из `SVOI-Flutter` переносятся автоматически; исходная папка сохраняется. Если в `SVOI` уже были данные прежнего WebView-клиента, они сохраняются отдельно в `SVOI-backup-…`. Папки данных и коды переноса содержат доступ к подпискам — не публикуйте их.

</details>

## Статус проекта

**Windows: 0.6.0-beta.4 · x64. Android: 0.1.0-preview.8 · ARM64 и x86_64. Linux: 0.6.0-preview.2 · x64.** iOS пока не выпускается. SVOI использует ваши подписки; VPN-серверы в комплект не входят.

Android — отдельная экспериментальная сборка: [APK для ARM64-телефонов](https://github.com/1atex/svoi/releases/download/android-v0.1.0-preview.8/SVOI-Android-0.1.0-preview.8-arm64.apk), [APK для эмулятора x86_64](https://github.com/1atex/svoi/releases/download/android-v0.1.0-preview.8/SVOI-Android-0.1.0-preview.8-x64.apk), [инструкция и исходники Android](https://github.com/1atex/svoi/blob/android-preview/docs/ANDROID.md). Обновления проверяются и скачиваются из приложения; установку подтверждает пользователь. Preview 8 добавляет восемь тем, хэллоуинскую кнопку и Telegram. Устанавливается поверх Preview 7 с сохранением данных. При переходе с Preview 5 сохраните коды профилей и переустановите приложение: начиная с Preview 6 используется постоянная подпись.

Linux Preview: [`.deb` и переносимый архив](https://github.com/1atex/svoi/releases/tag/linux-v0.6.0-preview.2), [инструкция](docs/LINUX.md). Поддерживаются TUN, локальный прокси, подписки, темы и перенос профилей. Системный DNS остаётся под управлением Linux; выбор приложений, Windows zapret и автоустановка обновлений в Linux пока отсутствуют. Сборки проверяются на Ubuntu 22.04, в изолированной сети и под Xvfb/Openbox.

- Проверка одного HTTPS-адреса не гарантирует доступность всех сайтов. «Нет ответа» не блокирует подключение.
- Совместимость TUN и zapret зависит от стратегии и сети. Kill switch пока отсутствует.
- Перенос профиля не отменяет серверные ограничения провайдера.

Нашли проблему? [Создайте issue](https://github.com/1atex/svoi/issues), укажите версию, режим подключения и шаги воспроизведения. Удалите из журналов ключи, ссылки на подписки и коды переноса.

---

<details>
<summary><b>Разработчикам: сборка, архитектура и выпуск релизов</b></summary>

## Разработка

- [Flutter: сборка, тесты и архитектура](flutter_client/README.md)
- [Примечания к релизу](flutter_client/RELEASE-NOTES.md)
- [Структура исходников](docs/DEVELOPMENT.md)
- [Измерения производительности](docs/PERFORMANCE.md)

Нужны Go, Flutter 3.47.7, Visual Studio с C++ Desktop workload и Inno Setup 6:

```powershell
./scripts/prepare-core.ps1
./flutter_client/build-prototype.ps1 -FlutterSdk C:/path/to/flutter
```

Скрипт проверяет исходники и собирает приложение, ZIP, установщик и SHA-256 в `releases/v<версия>/`. SDK, пользовательские данные и сборки исключены из Git.

## Выпуск обновления

1. Обновите `nativeVersion` в `backend/main.go`, версию в `flutter_client/pubspec.yaml`, `clientVersion` в `flutter_client/lib/features.dart`, версию сборочного скрипта и release notes.
2. Выполните проверки и соберите пакет локально.
3. Отправьте коммит и тег `v<версия>` в GitHub.

Workflow `.github/workflows/release.yml` проверит версии, скачает закреплённые SDK и Xray с проверкой SHA-256, выполнит тесты и опубликует установщик, ZIP и контрольные суммы. Beta и стабильные версии публикуются обычным Release с отметкой Latest; prebeta и rc — как prerelease. Дождитесь успешного workflow перед объявлением релиза. Клиенты принимают установщик своего канала и проверяют его digest из GitHub API.

Иконки экспортируются из исходной аватарки: `python assets/brand/export-icons.py` (Pillow).

</details>

## Лицензия

SVOI распространяется под [MIT](LICENSE). Лицензии Xray, Wintun, Flutter и зависимостей включены в дистрибутив.

<p align="center"><b>На связи со своими.</b></p>
