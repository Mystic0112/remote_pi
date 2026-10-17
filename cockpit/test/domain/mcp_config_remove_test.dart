import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/data/agents/desktop_agent_apps_impl.dart';
import 'package:cockpit/app/cockpit/domain/entities/desktop_agent_app.dart';
import 'package:cockpit/app/cockpit/domain/services/mcp_config_merge.dart';
import 'package:cockpit/app/cockpit/ui/actions/desktop_integration_actions.dart';
import 'package:cockpit/app/core/domain/contracts/settings_store.dart';
import 'package:cockpit/app/core/domain/entities/app_settings.dart';
import 'package:cockpit/app/core/ui/settings_controller.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter_test/flutter_test.dart';

const _cli = '/home/u/.cockpit/bin/cockpit';
const _args = ['mcp', '--agent', 'cursor'];

void main() {
  codexOptOut();
  group('removeJsonMcpServer', () {
    test('desfaz o merge e preserva o resto byte a byte', () {
      const before =
          '{\n'
          '    "theme": "dark",\n'
          '    "mcpServers": {\n'
          '        "a": {"command": "x", "args": [1, 2]}\n'
          '    }\n'
          '}\n';
      final merged = mergeJsonMcpServer(before, command: _cli, args: _args);
      final removed = removeJsonMcpServer(merged);
      expect(jsonDecode(removed), jsonDecode(before));
      expect(removed, isNot(contains('cockpit')));
      expect(removeJsonMcpServer(removed), removed, reason: 'idempotente');
    });

    test('meio, fim e único: só a entrada (com a vírgula) sai', () {
      // Formatação do usuário (arrays em linha, espaços) fica intacta.
      const middle =
          '{\n'
          '  "mcpServers": {\n'
          '    "a": {"args": [1, 2]},\n'
          '    "cockpit": {\n'
          '      "command": "/c", "args": ["mcp"]\n'
          '    },\n'
          '    "b": {"args": ["}", "\\"{"]}\n'
          '  },\n'
          '  "x": 1\n'
          '}\n';
      expect(
        removeJsonMcpServer(middle),
        '{\n'
        '  "mcpServers": {\n'
        '    "a": {"args": [1, 2]},\n'
        '    "b": {"args": ["}", "\\"{"]}\n'
        '  },\n'
        '  "x": 1\n'
        '}\n',
      );
      expect(
        removeJsonMcpServer(
          '{"mcpServers": {"a": {}, "cockpit": {"command": "/c"}}}',
        ),
        '{"mcpServers": {"a": {}}}',
      );
      expect(
        removeJsonMcpServer('{"mcpServers": {"cockpit": {"command": "/c"}}}'),
        '{"mcpServers": {}}',
      );
      expect(
        removeJsonMcpServer(
          '{"mcpServers": {"cockpit": {}, "b": 1}, "cockpit": 2}',
        ),
        '{"mcpServers": {"b": 1}, "cockpit": 2}',
        reason: 'só a de mcpServers, não uma homônima em outro nível',
      );
    });

    test('sem entrada: intacto; inválido: FormatException', () {
      const raw = '{ "mcpServers": { "a": {} } }';
      expect(removeJsonMcpServer(raw), raw);
      expect(removeJsonMcpServer(''), '');
      expect(() => removeJsonMcpServer('// c\n{}'), throwsFormatException);
      expect(() => removeJsonMcpServer('[1]'), throwsFormatException);
    });
  });

  group('removeTomlMcpServer', () {
    const toml = ['mcp', '--agent', 'codex-desktop'];

    test('inverso exato do append (no fim e antes de outra tabela)', () {
      const before = 'model = "gpt-5.6"\n\n[profiles.x]\nmodel = "o3"\n';
      final merged = mergeTomlMcpServer(before, command: _cli, args: toml);
      expect(merged, contains('env_vars'));
      expect(removeTomlMcpServer(merged), before);

      // Tabela no meio (o Codex a gravou antes do bloco de hooks).
      const head = 'model = "gpt-5.6"\n';
      const tail = '# >>> cockpit hooks (auto-gerado)\n[hooks.state."k"]\n';
      final middle = '$head\n${tomlMcpEntry(command: _cli, args: toml)}\n$tail';
      expect(removeTomlMcpServer(middle), '$head\n$tail');
    });

    test('leva subtabelas da cockpit; não toca outras nem chave à mão', () {
      const raw =
          '[mcp_servers.other]\ncommand = "o"\n\n'
          '[mcp_servers.cockpit]\ncommand = "c"\nenv_vars = ["A"]\n\n'
          '[mcp_servers.cockpit.env]\nX = "1"\n\n'
          '[mcp_servers.cockpitx]\ncommand = "y"\n';
      expect(
        removeTomlMcpServer(raw),
        '[mcp_servers.other]\ncommand = "o"\n\n'
        '[mcp_servers.cockpitx]\ncommand = "y"\n',
      );
      const dotted = 'mcp_servers.cockpit.command = "meu"\n';
      expect(removeTomlMcpServer(dotted), dotted);
      expect(removeTomlMcpServer(''), '');
    });
  });

  group('DesktopAgentAppsImpl.uninstall', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('mcp-rm'));
    tearDown(() => dir.delete(recursive: true));

    DesktopAppIntegration at(String path, DesktopAgentApp app) =>
        DesktopAppIntegration(app: app, configPath: path, entry: '');

    test('backup antes, só a entrada sai, edição posterior fica', () async {
      final f = File('${dir.path}/mcp.json');
      // Config depois do install + uma edição do usuário (servidor "b").
      final edited = mergeJsonMcpServer(
        '{\n  "mcpServers": {\n    "a": {}\n  }\n}\n',
        command: _cli,
        args: _args,
      ).replaceFirst('"a": {}', '"a": {},\n    "b": {"command": "new"}');
      f.writeAsStringSync(edited);

      const apps = DesktopAgentAppsImpl();
      final r = await apps.uninstall(at(f.path, DesktopAgentApp.cursor));
      expect(r, isA<Success<void, DesktopAppError>>());
      final out = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      expect(out['mcpServers'], {
        'a': <String, Object?>{},
        'b': {'command': 'new'},
      });
      final baks = dir
          .listSync()
          .where((e) => e.path.contains('.cockpit-bak-'))
          .toList();
      expect(baks, hasLength(1));
      expect(File(baks.single.path).readAsStringSync(), edited);
      if (!Platform.isWindows) {
        final bits = FileStat.statSync(baks.single.path).mode & 0x1ff;
        expect(bits.toRadixString(8), '600');
      }

      // Já sem a entrada (ou sem arquivo): no-op, sem backup novo.
      await apps.uninstall(at(f.path, DesktopAgentApp.cursor));
      await apps.uninstall(at('${dir.path}/none.json', DesktopAgentApp.cursor));
      expect(
        dir.listSync().where((e) => e.path.contains('-bak-')),
        hasLength(1),
      );
    });

    test('config que não dá pra editar: invalidConfig, nada gravado', () async {
      final f = File('${dir.path}/config.json')
        ..writeAsStringSync('// jsonc\n{"mcpServers": {"cockpit": {}}}');
      final r = await const DesktopAgentAppsImpl().uninstall(
        at(f.path, DesktopAgentApp.claudeDesktop),
      );
      expect(
        r.fold((_) => null, (e) => e.kind),
        DesktopAppErrorKind.invalidConfig,
      );
      expect(f.readAsStringSync(), startsWith('// jsonc'));
    });
  });
}

class _Store implements SettingsStore {
  AppSettings saved = const AppSettings();
  @override
  Future<AppSettings> load() async => saved;
  @override
  Future<void> save(AppSettings settings) async => saved = settings;
}

/// Grava em [path] como o impl, sem detectar app nem exigir a CLI.
class _Apps extends DesktopAgentAppsImpl {
  const _Apps();
  @override
  Future<Result<void, DesktopAppError>> install(DesktopAppIntegration i) async {
    final f = File(i.configPath);
    f.writeAsStringSync(
      mergeTomlMcpServer(
        f.existsSync() ? f.readAsStringSync() : null,
        command: _cli,
        args: mcpServerArgs(i.app.id),
      ),
    );
    return const Success(null);
  }
}

void codexOptOut() {
  test(
    'Codex: remover desliga a reinstalação no boot; adicionar religa',
    () async {
      final dir = await Directory.systemTemp.createTemp('mcp-codex');
      addTearDown(() => dir.delete(recursive: true));
      final settings = SettingsController(_Store());
      final codex = DesktopAppIntegration(
        app: DesktopAgentApp.codexDesktop,
        configPath: '${dir.path}/config.toml',
        entry: '',
      );
      expect(settings.settings.codexMcpIntegration, isTrue, reason: 'default');
      await addDesktopIntegration(const _Apps(), settings, codex);
      expect(
        File(codex.configPath).readAsStringSync(),
        contains('[mcp_servers.cockpit]'),
      );
      await removeDesktopIntegration(const _Apps(), settings, codex);
      expect(
        File(codex.configPath).readAsStringSync(),
        isNot(contains('cockpit]')),
      );
      expect(settings.settings.codexMcpIntegration, isFalse);
      expect(settings.settings.toJson()['codexMcpIntegration'], isFalse);
      expect(
        AppSettings.fromJson(settings.settings.toJson()).codexMcpIntegration,
        isFalse,
      );
      await addDesktopIntegration(const _Apps(), settings, codex);
      expect(settings.settings.codexMcpIntegration, isTrue);

      // Outros apps não mexem na flag do Codex.
      await removeDesktopIntegration(
        const _Apps(),
        settings,
        DesktopAppIntegration(
          app: DesktopAgentApp.cursor,
          configPath: '${dir.path}/none.json',
          entry: '',
        ),
      );
      expect(settings.settings.codexMcpIntegration, isTrue);
    },
  );
}
