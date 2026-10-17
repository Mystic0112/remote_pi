import 'dart:io';

import 'package:cockpit/app/cockpit/data/hooks/terminal_status_server_impl.dart';
import 'package:flutter_test/flutter_test.dart';

/// O socket do app é o mesmo para as abas (`COCKPIT_STATUS_SOCK`) e para a CLI
/// de fora delas (caminho bem conhecido): só o dono pode alcançá-lo.
void main() {
  test(
    'socket Unix nasce 0600 numa pasta 0700, mesmo com umask frouxo',
    () async {
      final root = await Directory.systemTemp.createTemp('status-sock');
      addTearDown(() => root.delete(recursive: true));
      // Pasta pré-existente frouxa (o `~/.cockpit` 0775 de antes) e socket
      // órfão do ciclo anterior.
      final dir = Directory('${root.path}/.cockpit')..createSync();
      await Process.run('chmod', ['775', dir.path]);
      final path = '${dir.path}/status.sock';
      final stale = await bindPrivateUnixSocket(path);
      await stale.close();
      await Process.run('chmod', ['777', path]);

      final server = await bindPrivateUnixSocket(path);
      addTearDown(server.close);
      int bits(String p) => FileStat.statSync(p).mode & 0x1ff;
      expect(bits(dir.path).toRadixString(8), '700');
      expect(bits(path).toRadixString(8), '600');
      expect(
        FileSystemEntity.typeSync(path),
        FileSystemEntityType.unixDomainSock,
      );

      // E segue atendendo o dono.
      server.listen((s) => s.destroy());
      final client = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      client.destroy();
    },
    skip: Platform.isWindows ? 'POSIX only (Windows usa TCP + token)' : false,
  );
}
