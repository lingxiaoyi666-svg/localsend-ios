import 'package:flutter/material.dart';
import 'package:localsend_app/model/state/network_state.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// "Why can't the other device see me?" self check.
/// Shows the facts LocalSend depends on (addresses, port, protocol) and the
/// usual suspects, without leaving the app.
class NetworkDiagnosticsPage extends StatelessWidget {
  const NetworkDiagnosticsPage();

  static String _text(BuildContext context, {required String zh, required String en}) {
    return Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  }

  Future<void> _restart(BuildContext context) async {
    final ref = context.ref;
    final messenger = ScaffoldMessenger.of(context);
    await ref.notifier(serverProvider).restartServerFromSettings();
    messenger.showSnackBar(
      SnackBar(
        content: Text(_text(context, zh: '服务器已重启', en: 'Server restarted')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final NetworkState network = context.watch(localIpProvider);
    final settings = context.watch(settingsProvider);
    final serverState = context.watch(serverProvider.select((s) => s));

    final ips = network.localIps;
    final linkLocal = ips.where((ip) => ip.startsWith('169.254.')).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_text(context, zh: '网络自检', en: 'Network self check')),
      ),
      body: ResponsiveListView(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
        children: [
          _SectionTitle(_text(context, zh: '本机地址', en: 'This device')),
          if (ips.isEmpty)
            _Row(
              label: _text(context, zh: '地址', en: 'Addresses'),
              value: _text(context, zh: '未获取到（检查是否已连接 Wi-Fi）', en: 'none (check the Wi-Fi connection)'),
              warn: true,
            )
          else
            for (final ip in ips) _Row(label: _text(context, zh: 'IPv4', en: 'IPv4'), value: ip, warn: ip.startsWith('169.254.')),
          _Row(label: _text(context, zh: '端口', en: 'Port'), value: '${serverState?.port ?? settings.port} (TCP + UDP)'),
          _Row(label: _text(context, zh: '加密 (HTTPS)', en: 'Encryption (HTTPS)'), value: settings.https ? 'on' : 'off'),
          _Row(
            label: _text(context, zh: '组播组', en: 'Multicast group'),
            value: settings.multicastGroup.isEmpty ? '224.0.0.167' : settings.multicastGroup,
          ),
          _Row(label: _text(context, zh: '设备名', en: 'Device name'), value: settings.alias),
          const SizedBox(height: 10),
          _SectionTitle(_text(context, zh: '自查清单', en: 'Checklist')),
          _Bullet(
            _text(
              context,
              zh: '两台设备必须连同一个 Wi-Fi / 同一网段。iOS 首次运行必须允许「本地网络」权限，否则永远搜不到设备。',
              en: 'Both devices must be on the same Wi-Fi / subnet. On iOS the "Local Network" permission is mandatory.',
            ),
          ),
          _Bullet(
            _text(
              context,
              zh: '路由器若开了「AP 隔离 / 客户端隔离」，设备之间互相不可见，需要在路由器里关掉。',
              en: 'If the router has "AP isolation / client isolation" enabled, devices cannot see each other.',
            ),
          ),
          _Bullet(
            _text(
              context,
              zh: 'Windows 上把当前网络配置文件设为「专用」，否则防火墙会挡掉 53317 的入站。',
              en: 'On Windows set the network profile to "Private", otherwise the firewall blocks inbound 53317.',
            ),
          ),
          _Bullet(
            _text(
              context,
              zh: '公司 / 酒店网络常封组播，可改用「通过链接分享」或手动输入 IP。',
              en: 'Corporate / hotel networks often block multicast. Use "share via link" or enter the IP manually.',
            ),
          ),
          if (linkLocal.isNotEmpty)
            _Bullet(
              _text(
                context,
                zh: '检测到 169.254.x.x 地址：DHCP 没拿到地址，这条路不通。',
                en: 'A 169.254.x.x address was found: DHCP failed, this interface cannot work.',
              ),
              warn: true,
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => _restart(context),
            child: Text(_text(context, zh: '重启服务器', en: 'Restart server')),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 10),
      child: Text(text, style: Theme.of(context).textTheme.titleLarge),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool warn;

  const _Row({required this.label, required this.value, this.warn = false});

  @override
  Widget build(BuildContext context) {
    final color = warn ? Colors.orange : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: TextStyle(color: color)),
          ),
          Expanded(child: SelectableText(value, style: TextStyle(color: color))),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  final bool warn;

  const _Bullet(this.text, {this.warn = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•  ', style: TextStyle(color: warn ? Colors.orange : null)),
          Expanded(child: Text(text, style: TextStyle(color: warn ? Colors.orange : null))),
        ],
      ),
    );
  }
}
