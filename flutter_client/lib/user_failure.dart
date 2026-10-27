import 'backend.dart';

class UserFailure {
  const UserFailure(this.title, this.action);
  final String title, action;
  String get text => '$title. $action';
}

UserFailure subscriptionFailure(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('http 401') || text.contains('http 403')) {
    return const UserFailure(
      'Провайдер отклонил подписку',
      'Проверьте срок подписки и ссылку в личном кабинете провайдера.',
    );
  }
  if (text.contains('http 404') || text.contains('http 410')) {
    return const UserFailure(
      'Ссылка на подписку недействительна',
      'Получите новую ссылку у провайдера и замените её в настройках подписки.',
    );
  }
  if (text.contains('http 429') ||
      (error is ApiException && error.status == 429)) {
    return const UserFailure(
      'Слишком много обновлений',
      'Подождите минуту и повторите попытку.',
    );
  }
  if (RegExp(r'http 30[12378]').hasMatch(text)) {
    return const UserFailure(
      'Ссылка перенаправляет на другой адрес',
      'Скопируйте конечную HTTPS-ссылку из личного кабинета провайдера.',
    );
  }
  if (text.contains('формат') ||
      text.contains('конфигурац') ||
      text.contains('серверов') ||
      (error is ApiException && error.status == 413)) {
    return const UserFailure(
      'Не удалось прочитать конфигурации',
      'Проверьте ссылку: нужен адрес подписки, а не страница сайта. Сохранённые серверы доступны.',
    );
  }
  if (text.contains('сертификат') || text.contains('certificate')) {
    return const UserFailure(
      'Не удалось проверить сертификат провайдера',
      'Проверьте дату и время Windows. Если они верны, обратитесь к провайдеру.',
    );
  }
  return const UserFailure(
    'Подписка не обновилась',
    'Проверьте интернет и повторите попытку. Можно подключиться к сохранённым серверам.',
  );
}

UserFailure connectionFailure(
  String error, {
  required bool running,
  bool available = true,
}) {
  final text = error.toLowerCase();
  if (text.contains('администратор') || text.contains('administrator')) {
    return const UserFailure(
      'Нужны права администратора',
      'Закройте SVOI и запустите его от имени администратора, затем подключитесь снова.',
    );
  }
  if (text.contains('zapret') || text.contains('winws')) {
    return UserFailure('Подключению мешает zapret', error);
  }
  if (text.contains('локальн') && text.contains('сервис')) {
    return const UserFailure(
      'Нет связи с локальным сервисом SVOI',
      'Закройте приложение через «Отключить и выйти» в трее и запустите его снова.',
    );
  }
  if (running && (text.contains('конфигурац') || text.contains('профил'))) {
    return const UserFailure(
      'Новый профиль не запустился',
      'Предыдущее соединение сохранено. Обновите подписку или выберите другой сервер.',
    );
  }
  if (running) {
    return const UserFailure(
      'Интернет не подтверждён',
      'VPN остаётся включён. Если сайты не открываются, повторите проверку или смените сервер.',
    );
  }
  if (!available || text.contains('ядро xray не найдено')) {
    return const UserFailure(
      'Ядро VPN недоступно',
      'Переустановите SVOI через установщик. Для portable-версии распакуйте весь архив.',
    );
  }
  if (text.contains('конфигурац') || text.contains('профил')) {
    return const UserFailure(
      'Сервер содержит неподходящую конфигурацию',
      'Обновите подписку или выберите другой сервер. Подробности сохранены в диагностике.',
    );
  }
  if (text.contains('сервер не найден')) {
    return const UserFailure(
      'Сервер больше недоступен в подписке',
      'Обновите подписку и выберите сервер из нового списка.',
    );
  }
  return const UserFailure(
    'Не удалось запустить соединение',
    'Повторите подключение. Если ошибка повторяется, выберите другой сервер и откройте диагностику.',
  );
}
