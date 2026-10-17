import 'dart:io';

import 'package:cockpit/app/cockpit/data/hooks/pi_hook_installer_impl.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory home;
  const installer = PiHookInstallerImpl();
  const cmd = '/home/u/.cockpit/bin/cockpit hook';
  File ext() =>
      File('${home.path}/.pi/agent/extensions/${PiHookInstallerImpl.fileName}');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('pi-hook-test');
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  test('sem ~/.pi (Pi nunca rodou): não cria nada', () async {
    await installer.writeConfig(home: home.path, command: cmd);
    expect(Directory('${home.path}/.pi').existsSync(), isFalse);
  });

  test(
    'instala a extensão com o comando e --harness pi; reboot não regrava',
    () async {
      await Directory('${home.path}/.pi').create();
      await installer.writeConfig(home: home.path, command: cmd);
      final content = ext().readAsStringSync();
      expect(content, startsWith(PiHookInstallerImpl.marker));
      expect(content, contains('"$cmd --harness pi"'));
      expect(content, contains('process.env.COCKPIT_PANE_ID'));
      for (final event in [
        'session_start',
        'agent_start',
        'agent_end',
        'tool_result',
      ]) {
        expect(content, contains('pi.on("$event"'), reason: event);
      }
      final stamp = ext().lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await installer.writeConfig(home: home.path, command: cmd);
      expect(ext().readAsStringSync(), content);
      expect(ext().lastModifiedSync(), stamp, reason: 'nada mudou: não grava');
    },
  );

  test('CLI mudou de lugar: regrava a nossa', () async {
    await Directory('${home.path}/.pi').create();
    await installer.writeConfig(home: home.path, command: cmd);
    await installer.writeConfig(
      home: home.path,
      command: '"/Users/John Smith/.cockpit/bin/cockpit" hook',
    );
    expect(
      ext().readAsStringSync(),
      contains(
        r'"\"/Users/John Smith/.cockpit/bin/cockpit\" hook --harness pi"',
      ),
    );
  });

  test(
    'arquivo do usuário com o mesmo nome (sem marcador) fica intacto',
    () async {
      await ext().create(recursive: true);
      ext().writeAsStringSync('export default () => {};\n');
      await installer.writeConfig(home: home.path, command: cmd);
      expect(ext().readAsStringSync(), 'export default () => {};\n');
    },
  );
}
