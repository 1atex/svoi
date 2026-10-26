import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:country_flags/country_flags.dart';

import 'countries.dart';

import 'backend.dart';
import 'controller.dart';
import 'demo.dart';
import 'data_directory.dart';
part 'features.dart';
part 'design.dart';
part 'overview.dart';
part 'desktop_workspace.dart';
part 'power_control.dart';
part 'connection_view.dart';
part 'connection_card.dart';
part 'servers.dart';
part 'zapret_page.dart';
part 'tray.dart';
part 'startup_panel.dart';
part 'network_tools.dart';
part 'subscription_details.dart';

const windowChannel = MethodChannel('dev.svoi/window');
const canvas = Color(0xff101013),
    surface = Color(0xff19191e),
    edge = Color(0xff303037),
    muted = Color(0xffaaa8a3),
    accent = Color(0xffe7b96a),
    raised = Color(0xff232329),
    ink = Color(0xfff4f2ed),
    success = Color(0xff91d9b5);
void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    Bootstrap(
      demo: args.contains('--demo'),
      startup: args.contains('--startup'),
    ),
  );
}

ThemeData svoiTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  fontFamily: 'Segoe UI',
  splashFactory: NoSplash.splashFactory,
  hoverColor: Colors.white.withValues(alpha: .04),
  listTileTheme: const ListTileThemeData(
    iconColor: muted,
    textColor: ink,
    selectedColor: accent,
  ),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(foregroundColor: muted),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      foregroundColor: accent,
      textStyle: const TextStyle(
        fontFamily: 'Segoe UI',
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    ),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: surface,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: edge),
    ),
  ),
  colorScheme: const ColorScheme.dark(
    primary: accent,
    onPrimary: canvas,
    surface: surface,
    onSurface: Color(0xfff4f2ed),
    outline: edge,
    error: Color(0xffffaaa6),
  ),
  scaffoldBackgroundColor: canvas,
  dividerColor: edge,
  dividerTheme: const DividerThemeData(color: edge, thickness: 1, space: 1),
  cardTheme: const CardThemeData(elevation: 0),
  chipTheme: ChipThemeData(
    backgroundColor: surface,
    selectedColor: accent.withValues(alpha: .12),
    side: const BorderSide(color: edge),
    checkmarkColor: accent,
    labelStyle: const TextStyle(
      fontFamily: 'Segoe UI',
      fontSize: 12,
      color: ink,
    ),
    iconTheme: const IconThemeData(color: muted, size: 15),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(100, 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(100, 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: canvas,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: edge),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: edge),
    ),
  ),
  scrollbarTheme: const ScrollbarThemeData(
    thumbColor: WidgetStatePropertyAll(Color(0xff64676e)),
    thickness: WidgetStatePropertyAll(6),
    radius: Radius.circular(6),
  ),
  tooltipTheme: const TooltipThemeData(
    waitDuration: Duration(milliseconds: 500),
  ),
);

class Bootstrap extends StatefulWidget {
  const Bootstrap({
    super.key,
    this.demo = false,
    this.startup = false,
    this.backend,
  });
  final bool demo;
  final bool startup;
  final Backend? backend;
  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> with WidgetsBindingObserver {
  SvoiController? _controller;
  String? _error;
  bool _ready = false, _closing = false;
  late final Future<void> _launch;
  final _shellKey = GlobalKey<_SvoiShellState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowChannel.setMethodCallHandler((call) async {
      if (call.method == 'requestClose') await _close();
      if (call.method == 'visibility') {
        _controller?.visibility(call.arguments == true);
      }
      if (call.method == 'trayAction' && call.arguments is String) {
        await _shellKey.currentState?._tray.handle(call.arguments as String);
      }
    });
    unawaited(windowChannel.invokeMethod('ready'));
    _launch = _start();
  }

  Future<void> _start() async {
    try {
      final data = widget.demo
          ? Directory.systemTemp
          : await prepareDataDirectory();
      final api =
          widget.backend ??
          (widget.demo
              ? DemoBackend()
              : await NativeBackend.launch(data, startup: widget.startup));
      _controller = SvoiController(
        api,
        sessionFile: widget.demo ? null : File('${data.path}/session.json'),
      );
      await _controller!.initialize();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      await _controller?.close();
      if (mounted) {
        setState(() {
          _ready = false;
          _error = e.toString();
        });
      }
      if (widget.startup) await windowChannel.invokeMethod('show');
      return;
    }
    if (widget.startup && mounted && !_closing) {
      try {
        final api = _controller!.api;
        final zapret = await api.request('zapret');
        if (zapret['error']?.toString().isNotEmpty == true) {
          _controller!.message.value = zapret['error'].toString();
          await windowChannel.invokeMethod('show');
        } else {
          await windowChannel.invokeMethod('tray');
        }
      } catch (e) {
        _controller!.message.value = 'Не удалось завершить запуск в трее: $e';
        try {
          await windowChannel.invokeMethod('show');
        } catch (_) {}
      }
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    if (_controller == null) await _launch;
    await _controller?.close();
    await windowChannel.invokeMethod('close');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller?.visibility(
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'SVOI',
    theme: svoiTheme(),
    builder: (context, child) => _controller == null
        ? child!
        : ValueListenableBuilder(
            valueListenable: _controller!.foreground,
            child: child,
            builder: (context, visible, child) =>
                TickerMode(enabled: visible, child: child!),
          ),
    home: _closing
        ? const Scaffold(body: Center(child: Text('Завершаем соединение…')))
        : _ready
        ? SvoiShell(key: _shellKey, controller: _controller!, demo: widget.demo)
        : Scaffold(
            body: Center(
              child: SizedBox(
                width: 520,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.shield_outlined,
                        size: 44,
                        color: accent,
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'SVOI',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (_error == null)
                        const LinearProgressIndicator()
                      else
                        SelectableText(
                          _error!,
                          style: const TextStyle(color: Color(0xffffaaa6)),
                        ),
                      const SizedBox(height: 16),
                      Text(
                        _error == null
                            ? 'Запускаем локальный сервис…'
                            : 'Закройте окно и запустите SVOI повторно.',
                        style: const TextStyle(color: muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
  );
}

class SvoiShell extends StatefulWidget {
  const SvoiShell({super.key, required this.controller, this.demo = false});
  final SvoiController controller;
  final bool demo;
  @override
  State<SvoiShell> createState() => _SvoiShellState();
}

class _SvoiShellState extends State<SvoiShell> {
  int page = 0;
  late final TrayBridge _tray;
  bool _trayDialogOpen = false;
  @override
  void initState() {
    super.initState();
    _tray = TrayBridge(widget.controller, open: _openTrayAction)..attach();
    widget.controller.approveZapretPause = () async {
      await windowChannel.invokeMethod('show');
      if (!mounted) return 'cancel';
      return await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Приостановить zapret?'),
              content: const Text(
                'Для подключения TUN SVOI остановит свою стратегию zapret и вернёт её после отключения VPN. Если VPN не запустится, zapret тоже будет восстановлен.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, 'cancel'),
                  child: const Text('Отмена'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'always'),
                  child: const Text('Всегда переключать'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, 'once'),
                  child: const Text('Продолжить'),
                ),
              ],
            ),
          ) ??
          'cancel';
    };
  }

  Future<void> _openTrayAction(String action) async {
    if (!mounted) return;
    await windowChannel.invokeMethod('show');
    if (!mounted) return;
    if (action == 'servers' || action == 'settings' || action == 'connection') {
      setState(() => page = action == 'settings' ? 5 : 0);
      return;
    }
    if (_trayDialogOpen) return;
    _trayDialogOpen = true;
    try {
      if (action == 'import') await importDialog(context, widget.controller);
      if (action == 'logs' && mounted) {
        await showLogs(context, widget.controller);
      }
    } finally {
      _trayDialogOpen = false;
    }
  }

  @override
  void dispose() {
    _tray.dispose();
    widget.controller.approveZapretPause = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      body: Column(
        children: [
          Material(
            color: const Color(0xff141417),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  const SizedBox(width: 120, height: 40, child: BrandMark()),
                  const SizedBox(width: 28),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final (index, label, icon) in [
                            (0, 'Подключение', LucideIcons.power),
                            (4, 'zapret', LucideIcons.shield),
                            (6, 'DNS', LucideIcons.network),
                            (5, 'Настройки', LucideIcons.settings2),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  foregroundColor: page == index
                                      ? accent
                                      : muted,
                                  backgroundColor: page == index
                                      ? accent.withValues(alpha: .12)
                                      : Colors.transparent,
                                  minimumSize: const Size(0, 42),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                onPressed: () => setState(() => page = index),
                                icon: Icon(icon, size: 17),
                                label: Text(label),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Профили и перенос',
                    onPressed: () => showDesktopSheet(
                      context,
                      'Профили и перенос',
                      ProfilePage(c: c),
                    ),
                    icon: const Icon(LucideIcons.users, size: 19),
                  ),
                  IconButton(
                    tooltip: 'Свернуть в трей',
                    onPressed: () => windowChannel.invokeMethod('tray'),
                    icon: const Icon(LucideIcons.chevronDown, size: 19),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          ValueListenableBuilder(
            valueListenable: c.message,
            builder: (context, message, _) => message.isEmpty
                ? const SizedBox.shrink()
                : Material(
                    color: const Color(0xff382327),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
                      child: Row(
                        children: [
                          const Icon(
                            LucideIcons.info,
                            size: 18,
                            color: Color(0xffffaaa6),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              message,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Закрыть сообщение',
                            onPressed: () => c.message.value = '',
                            icon: const Icon(LucideIcons.x, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          Expanded(
            child: switch (page) {
              4 => ZapretPage(c: c),
              5 => PreferencesPage(c: c),
              6 => DnsTools(c: c),
              _ => DesktopWorkspace(c: c),
            },
          ),
        ],
      ),
    );
  }
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Material(
    color: surface,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: edge),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Padding(padding: const EdgeInsets.all(22), child: child),
  );
}

Future<void> importDialog(BuildContext context, SvoiController c) async {
  var text = '';
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Добавить подписку'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'HTTPS-ссылка, VLESS / VMess / Trojan / SS / Hysteria2, JSON или код SVOI1. Перед переносом профиля будет показан его состав.',
              style: TextStyle(color: muted, fontSize: 13),
            ),
            const SizedBox(height: 18),
            TextField(
              onChanged: (value) => text = value,
              autofocus: true,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                hintText: 'Вставьте ссылку или конфигурацию',
              ),
              enableSuggestions: false,
              autocorrect: false,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            try {
              final path = await windowChannel.invokeMethod<String>('openFile');
              if (path == null || !context.mounted) return;
              final file = File(path);
              if (await file.length() > 12 * 1024 * 1024) {
                c.message.value = 'Файл больше 12 МБ';
                return;
              }
              final content = await file.readAsString();
              if (context.mounted) Navigator.pop(context, content);
            } catch (e) {
              c.message.value = 'Не удалось прочитать файл: $e';
              if (context.mounted) Navigator.pop(context);
            }
          },
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('Из файла'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            if (text.trim().isNotEmpty) Navigator.pop(context, text);
          },
          child: const Text('Добавить'),
        ),
      ],
    ),
  );
  if (value != null && context.mounted) {
    if (value.trim().startsWith('SVOI1.')) {
      await receivePreview(context, c, value.trim());
    } else {
      await c.importText(value);
    }
  }
}

Future<void> showConfig(
  BuildContext context,
  SvoiController c,
  ServerEntry server,
) async {
  final future = c.config(server);
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          CountryMark(country: server.country),
          const SizedBox(width: 12),
          Expanded(child: Text(server.country.title)),
        ],
      ),
      content: SizedBox(
        width: 760,
        height: 420,
        child: FutureBuilder(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return SelectableText(snapshot.error.toString());
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data!;
            return DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  Text(
                    'Правил: ${data['rules']} · балансировщиков: ${data['balancers']}. JSON содержит ключи доступа.',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                  const TabBar(
                    tabs: [
                      Tab(text: 'Для подключения'),
                      Tab(text: 'Исходная'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        for (final key in ['effective', 'original'])
                          ConfigPane(
                            c: c,
                            name: 'svoi-$key.json',
                            text: const JsonEncoder.withIndent('  ')
                                .convert(data[key]),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}

Future<void> showLogs(BuildContext context, SvoiController c) async {
  final future = c.logs();
  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Журнал Xray'),
      content: SizedBox(
        width: 760,
        height: 420,
        child: FutureBuilder(
          future: future,
          builder: (context, snapshot) => snapshot.hasError
              ? Text(snapshot.error.toString())
              : !snapshot.hasData
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  child: SelectableText(
                    (snapshot.data!['logs'] as List? ?? []).join('\n'),
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                    ),
                  ),
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}
