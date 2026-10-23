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
part 'features.dart';
part 'design.dart';
part 'overview.dart';
part 'power_control.dart';
part 'connection_view.dart';
part 'connection_card.dart';
part 'servers.dart';
part 'zapret_page.dart';
part 'tray.dart';

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
  runApp(Bootstrap(demo: args.contains('--demo')));
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
  const Bootstrap({super.key, this.demo = false});
  final bool demo;
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
      final data = Directory(
        Platform.environment['SVOI_FLUTTER_DATA'] ??
            '${Platform.environment['APPDATA'] ?? Directory.current.path}/SVOI-Flutter',
      );
      final api = widget.demo
          ? DemoBackend()
          : await NativeBackend.launch(data);
      _controller = SvoiController(
        api,
        sessionFile: widget.demo ? null : File('${data.path}/session.json'),
      );
      await _controller!.initialize();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      await _controller?.close();
      if (mounted) setState(() => _error = e.toString());
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
                            : 'Закройте окно и запустите прототип повторно.',
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
  }

  Future<void> _openTrayAction(String action) async {
    if (!mounted) return;
    await windowChannel.invokeMethod('show');
    if (!mounted) return;
    if (action == 'servers' || action == 'settings' || action == 'connection') {
      setState(
        () => page = action == 'servers'
            ? 1
            : action == 'settings'
            ? 5
            : 0,
      );
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 200,
            child: Material(
              color: const Color(0xff141417),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 28, 24, 32),
                    child: BrandMark(),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 0, 24, 14),
                    child: Eyebrow('ПРОСТРАНСТВО'),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final (index, label, icon) in [
                          (0, 'Подключение', LucideIcons.power),
                          (1, 'Серверы', LucideIcons.globe),
                          (2, 'Общий профиль', LucideIcons.users),
                          (3, 'Приложения', LucideIcons.appWindow),
                          (4, 'zapret', LucideIcons.shield),
                          (5, 'Настройки', LucideIcons.settings2),
                        ])
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            child: ListTile(
                              dense: true,
                              minTileHeight: 44,
                              horizontalTitleGap: 10,
                              minLeadingWidth: 24,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              selected: page == index,
                              selectedTileColor: const Color(0xff30291e),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              leading: Icon(icon, size: 18),
                              title: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                              onTap: () => setState(() => page = index),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.demo ? 'ДЕМОНСТРАЦИЯ' : 'WINDOWS · BETA',
                          style: const TextStyle(
                            color: muted,
                            fontSize: 10,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          clientVersion,
                          style: TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'На связи со своими.',
                          style: TextStyle(color: muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 20, 28, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          [
                            'Подключение',
                            'Серверы',
                            'Общий профиль',
                            'Приложения',
                            'zapret',
                            'Настройки',
                          ][page],
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Свернуть в трей',
                        icon: const Icon(LucideIcons.chevronDown),
                        onPressed: () => windowChannel.invokeMethod('tray'),
                      ),
                      ListenableBuilder(
                        listenable: Listenable.merge([
                          c.connection,
                          c.connectionPhase,
                          c.connectionIssue,
                        ]),
                        builder: (context, _) {
                          final view = ConnectionView(c);
                          return StatusPill(view.title, active: view.verified);
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ValueListenableBuilder(
                  valueListenable: c.message,
                  builder: (context, message, _) => message.isEmpty
                      ? const SizedBox.shrink()
                      : Container(
                          width: double.infinity,
                          color: const Color(0xff382327),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.info_outline,
                                color: Color(0xffffaaa6),
                                size: 18,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  message,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Закрыть сообщение',
                                onPressed: () => c.message.value = '',
                                icon: const Icon(Icons.close, size: 18),
                              ),
                            ],
                          ),
                        ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    child: KeyedSubtree(
                      key: ValueKey(page),
                      child: SizedBox.expand(
                        child: switch (page) {
                          0 => Overview(
                            c: c,
                            onServers: () => setState(() => page = 1),
                          ),
                          1 => ServerPage(c: c),
                          2 => ProfilePage(c: c),
                          3 => RoutingPage(c: c),
                          4 => ZapretPage(c: c),
                          _ => PreferencesPage(c: c),
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
              'HTTPS-ссылка, VLESS / VMess / Trojan / SS, JSON или код SVOI1. Перед переносом профиля будет показан его состав.',
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
