import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ApiException implements Exception {
  ApiException(this.message, [this.status = 0]);
  final String message;
  final int status;
  @override
  String toString() => message;
}

class RequestCancellation {
  bool cancelled = false;
  HttpClientRequest? request;
  void cancel() {
    cancelled = true;
    request?.abort();
  }
}

abstract class Backend {
  bool get mobile => false;
  String get platformName => 'Windows';
  String token = '';
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  });
  Future<void> close();
}

class NativeBackend extends Backend {
  NativeBackend._(
    this.process,
    this.address,
    this.key,
    this._output,
    this._errors,
  );
  final Process process;
  final Uri address;
  final String key;
  final StreamSubscription<String> _output;
  final StreamSubscription<String> _errors;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  bool _closed = false;

  static Future<NativeBackend> launch(
    Directory data, {
    bool startup = false,
  }) async {
    await data.create(recursive: true);
    final directory = File(Platform.resolvedExecutable).parent.path;
    final binary =
        Platform.environment['SVOI_BACKEND'] ??
        '$directory/backend/svoi-backend.exe';
    if (!await File(binary).exists()) {
      throw ApiException(
        'Не найден локальный сервис SVOI. Переустановите приложение или распакуйте весь архив.',
      );
    }
    final process = await Process.start(binary, [
      '-native-backend',
      '-desktop-exe',
      Platform.resolvedExecutable,
      if (startup) '-startup',
      '-listen',
      '127.0.0.1:0',
      '-data',
      '${data.path}/groups.json',
    ], workingDirectory: File(binary).parent.path);
    final ready = Completer<Map<String, dynamic>>();
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (ready.isCompleted) return;
          try {
            ready.complete(jsonDecode(line) as Map<String, dynamic>);
          } catch (_) {
            ready.completeError(
              ApiException('Неверный ответ локального сервиса.'),
            );
          }
        });

    final errors = process.stderr.transform(utf8.decoder).listen((_) {});
    unawaited(
      process.exitCode.then((code) {
        if (!ready.isCompleted) {
          ready.completeError(
            ApiException('Локальный сервис завершился при запуске ($code).'),
          );
        }
      }),
    );
    try {
      final result = await ready.future.timeout(const Duration(seconds: 20));
      final address = Uri.parse(result['address'] as String);
      if (address.scheme != 'http' ||
          address.host != '127.0.0.1' ||
          (result['key'] as String).isEmpty) {
        throw ApiException('Некорректный адрес локального сервиса.');
      }
      return NativeBackend._(
        process,
        address,
        result['key'] as String,
        output,
        errors,
      );
    } catch (_) {
      await process.stdin.close();
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        process.kill();
      }
      await output.cancel();
      await errors.cancel();
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (_closed) {
      throw ApiException('Локальный сервис остановлен. Перезапустите SVOI.');
    }
    if (cancellation?.cancelled == true) {
      throw ApiException('Запрос отменён.');
    }
    HttpClientRequest? request;
    try {
      request = await _client.openUrl(method, address.resolve('/api/$path'));
      cancellation?.request = request;
      if (cancellation?.cancelled == true) {
        request.abort();
        throw ApiException('Запрос отменён.');
      }
      request.headers.set('X-SVOI-Backend', key);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 40),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > 16 * 1024 * 1024) {
          throw ApiException('Ответ сервиса слишком большой.');
        }
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes);
      final Map<String, dynamic> json =
          response.headers.contentType?.mimeType == 'application/json'
          ? jsonDecode(text) as Map<String, dynamic>
          : {'text': text};
      if (response.statusCode >= 400) {
        throw ApiException(
          json['error']?.toString() ?? 'Ошибка сервиса',
          response.statusCode,
        );
      }
      return json;
    } on ApiException {
      rethrow;
    } catch (_) {
      request?.abort();
      throw ApiException(
        cancellation?.cancelled == true
            ? 'Запрос отменён.'
            : 'Нет ответа от локального сервиса.',
      );
    } finally {
      cancellation?.request = null;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 10));
    } catch (_) {
      process.kill();
    }
    await _output.cancel();
    await _errors.cancel();
  }
}
