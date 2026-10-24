import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'backend.dart';

class AndroidBackend extends Backend {
  AndroidBackend._(this.directory);
  static const channel = MethodChannel('dev.svoi/mobile');
  final Directory directory;
  @override
  bool get mobile => true;
  @override
  String get platformName => 'Android';
  static Future<AndroidBackend> launch() async {
    final result = jsonDecode(
      await channel.invokeMethod<String>('init') ?? '{}',
    );
    return AndroidBackend._(Directory(result['directory'] as String));
  }

  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (cancellation?.cancelled == true) throw ApiException('Запрос отменён.');
    try {
      final raw = await channel.invokeMethod<String>('request', {
        'path': path,
        'method': method,
        'body': jsonEncode(body ?? {}),
        'token': token,
      });
      if (cancellation?.cancelled == true) {
        throw ApiException('Запрос отменён.');
      }
      return Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map);
    } on PlatformException catch (e) {
      throw ApiException(
        e.message ?? 'Ошибка Android VPN',
        int.tryParse(e.code) ?? 0,
      );
    }
  }

  @override
  Future<void> close() async {}
}
