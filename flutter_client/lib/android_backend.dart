import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'backend.dart';

class AndroidBackend extends Backend {
  AndroidBackend._(this.directory, this.probeConcurrency);
  static const channel = MethodChannel('dev.svoi/mobile');
  final Directory directory;
  @override
  final int probeConcurrency;
  int _nextProbe = 0;
  @override
  bool get mobile => true;
  @override
  String get platformName => 'Android';
  static Future<AndroidBackend> launch() async {
    final result = jsonDecode(
      await channel.invokeMethod<String>('init') ?? '{}',
    );
    return AndroidBackend._(
      Directory(result['directory'] as String),
      ((result['probeConcurrency'] as int?) ?? 2).clamp(1, 2),
    );
  }

  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (cancellation?.cancelled == true) throw ApiException('Запрос отменён.');
    final probeID =
        (path.endsWith('/probe') ||
                path == 'connection/ip' ||
                path == 'dns/benchmark') &&
            method == 'POST'
        ? '${++_nextProbe}'
        : null;
    if (probeID != null && cancellation != null) {
      cancellation.onCancel = () {
        unawaited(
          channel
              .invokeMethod<void>('cancelProbe', {'id': probeID})
              .catchError((Object _) {}),
        );
      };
    }
    try {
      final raw = await channel.invokeMethod<String>('request', {
        'path': path,
        'method': method,
        'body': jsonEncode(body ?? {}),
        'token': token,
        'probeID': ?probeID,
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
    } finally {
      cancellation?.onCancel = null;
    }
  }

  @override
  Future<void> close() async {}
}
