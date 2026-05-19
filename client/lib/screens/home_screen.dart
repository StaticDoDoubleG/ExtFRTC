import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/peer.dart';
import '../services/discovery_service.dart';
import '../services/transfer_service.dart';
import '../utils/save_download.dart';
import 'transfer_screen.dart';

const _kServerUrlKey = 'signaling_server_url';
const _kManualIpKey = 'manual_vpn_ip';
const _kDefaultServerUrl = 'http://localhost:9090';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DiscoveryService? _discovery;
  TransferService? _transfer;
  String _signalingUrl = _kDefaultServerUrl;
  String _manualIp = '';
  List<Peer> _peers = [];
  List<String> _vpnHosts = [];
  String? _vpnInterface;
  String? _vpnCidr;
  bool _vpnAvailable = false;
  String? _vpnError;
  bool _scanning = false;
  final List<String> _logs = [];

  List<Peer> get _visiblePeers => _peers.where((peer) {
        if (_isLikelyGatewayAddress(peer.ip)) return false;
        final vpn = peer.wgIp;
        if (vpn != null && vpn.isNotEmpty && _isLikelyGatewayAddress(vpn)) {
          return false;
        }
        return true;
      }).toList();

  Peer? _peerForVpnHost(String ip) {
    for (final peer in _visiblePeers) {
      if (peer.wgIp == ip) {
        return peer;
      }
      if (peer.ip == ip) {
        return peer;
      }
      if (peer.candidateIps?.contains(ip) == true) {
        return peer;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _loadUrlAndInit();
  }

  String _normalizeServerUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return _kDefaultServerUrl;

    var candidate = trimmed;
    if (!candidate.startsWith('http://') && !candidate.startsWith('https://')) {
      candidate = 'http://$candidate';
    }

    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) return _kDefaultServerUrl;
    if (uri.scheme != 'http' && uri.scheme != 'https') return _kDefaultServerUrl;

    var path = uri.path;
    if (path == '/' || path.isEmpty) {
      path = '';
    } else {
      path = path.replaceAll(RegExp(r'/+$'), '');
    }

    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    ).toString();
  }

  Future<void> _loadUrlAndInit() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kServerUrlKey) ?? _kDefaultServerUrl;
    final savedIp = prefs.getString(_kManualIpKey) ?? '';
    final url = _normalizeServerUrl(saved);
    if (url != saved) {
      await prefs.setString(_kServerUrlKey, url);
    }
    _manualIp = savedIp;
    await _initServices(url, manualIp: savedIp);
    await _scan();
    await _refreshVpnScan();
  }

  Future<void> _initServices(String url, {String? manualIp}) async {
    await _transfer?.stopServer();
    _discovery?.dispose();

    _signalingUrl = url;
    if (manualIp != null) _manualIp = manualIp;

    _discovery = DiscoveryService(signalingBaseUrl: url, manualIp: _manualIp);
    _discovery!.peerStream.listen((peers) {
      if (mounted) setState(() => _peers = peers);
    });
    await _discovery!.register();

    _transfer = TransferService(signalingBaseUrl: url, manualIp: _manualIp);
    _transfer!.logStream.listen((log) {
      if (mounted) {
        setState(() {
          _logs.insert(0, log);
          if (_logs.length > 50) _logs.removeLast();
        });
      }
    });

    await _transfer!.startServer(
      onReceived: _onFileReceived,
      onTransferRequest: _onTransferRequest,
      onResolvePeerIp: (String peerId) {
        debugPrint('[Harness] Resolving IP for Peer: $peerId');
        for (final peer in _peers) {
          if (peer.id == peerId) {
            return [
              peer.ip,
              if (peer.wgIp != null && peer.wgIp!.isNotEmpty) peer.wgIp!,
            ];
          }
        }
        return null;
      },
    );
  }

  Future<bool> _onTransferRequest(String fromName, String fileName, int size) async {
    if (!mounted) return false;

    final mb = (size / (1024 * 1024)).toStringAsFixed(1);
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Incoming File'),
        content: Text('$fromName wants to send you "$fileName" ($mb MB).'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );

    final accepted = result ?? false;
    debugPrint('[Harness] Receiver responded to transfer request from $fromName: accepted=$accepted');
    return accepted;
  }

  /// Called on the main isolate when a peer sends us a file.
  void _onFileReceived(String fileName, Uint8List data) {
    saveDownload(fileName, data);
    if (!mounted) return;
    final kb = (data.length / 1024).toStringAsFixed(1);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Received "$fileName" (${kb} KB)'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    await _discovery?.discover();
    await _refreshVpnScan();
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _refreshVpnScan() async {
    final uri = Uri.tryParse(_signalingUrl);
    if (uri == null || uri.host.isEmpty) {
      if (mounted) {
        setState(() {
          _vpnAvailable = false;
          _vpnHosts = [];
          _vpnInterface = null;
          _vpnCidr = null;
          _vpnError = null;
        });
      }
      return;
    }

    final scanUri = uri.replace(path: '/vpn/scan', query: null, fragment: null);
    try {
      final res = await http.get(scanUri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        if (!mounted) return;
        setState(() {
          _vpnAvailable = false;
          _vpnHosts = [];
          _vpnInterface = null;
          _vpnCidr = null;
          _vpnError = 'VPN scan failed: HTTP ${res.statusCode}';
        });
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final hosts = (body['active_hosts'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .where((ip) => !_isLikelyGatewayAddress(ip))
          .toList()
        ..sort();

      if (!mounted) return;
      setState(() {
        _vpnAvailable = body['available'] == true;
        _vpnInterface = body['interface'] as String?;
        _vpnCidr = body['cidr'] as String?;
        _vpnHosts = hosts;
        _vpnError = body['error'] as String?;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _vpnAvailable = false;
        _vpnHosts = [];
        _vpnInterface = null;
        _vpnCidr = null;
        _vpnError = 'Failed to load VPN scan results: $e';
      });
    }
  }

  bool _isLikelyGatewayAddress(String ip) {
    final parts = ip.split('.');
    return parts.length == 4 && parts[3] == '1';
  }

  Future<void> _openServerSettings() async {
    final urlController = TextEditingController(text: _signalingUrl);
    final ipController = TextEditingController(text: _manualIp);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://10.0.0.1:9090',
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ipController,
              decoration: const InputDecoration(
                labelText: 'Manual VPN IP (Optional)',
                hintText: 'e.g. 10.11.23.13',
              ),
              keyboardType: TextInputType.number,
              autocorrect: false,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final newUrl = _normalizeServerUrl(urlController.text);
      final newIp = ipController.text.trim();
      
      final prefs = await SharedPreferences.getInstance();
      if (newUrl.isNotEmpty && newUrl != _signalingUrl) {
        await prefs.setString(_kServerUrlKey, newUrl);
      }
      if (newIp != _manualIp) {
        await prefs.setString(_kManualIpKey, newIp);
      }
      
      await _initServices(newUrl, manualIp: newIp);
      await _scan();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ExtFRTC'),
          actions: [
            IconButton(
              tooltip: 'Server settings',
              onPressed: _openServerSettings,
              icon: const Icon(Icons.dns),
            ),
            IconButton(
              tooltip: 'Scan for peers',
              onPressed: _scanning ? null : _scan,
              icon: _scanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.radar),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Peers', icon: Icon(Icons.devices)),
              Tab(text: 'VPN Peers', icon: Icon(Icons.hub)),
            ],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: TabBarView(
                children: [
                  _visiblePeers.isEmpty
                      ? _EmptyState(scanning: _scanning, onRetry: _scan)
                      : ListView.builder(
                          itemCount: _visiblePeers.length,
                          itemBuilder: (ctx, i) => _PeerTile(
                            peer: _visiblePeers[i],
                            onTap: () => Navigator.push(
                              ctx,
                              MaterialPageRoute(
                                builder: (_) => TransferScreen(
                                  peer: _visiblePeers[i],
                                  transfer: _transfer!,
                                ),
                              ),
                            ),
                          ),
                        ),
                  _VPNHostsTab(
                    available: _vpnAvailable,
                    interfaceName: _vpnInterface,
                    cidr: _vpnCidr,
                    hosts: _vpnHosts,
                    error: _vpnError,
                    resolvePeer: _peerForVpnHost,
                    transfer: _transfer,
                    onRefresh: _scan,
                    scanning: _scanning,
                  ),
                ],
              ),
            ),
            if (_logs.isNotEmpty)
              Container(
                height: 150,
                color: Colors.grey.shade100,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      color: Colors.grey.shade300,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Transfer Debug Logs',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          Row(
                            children: [
                              TextButton(
                                onPressed: () {
                                  setState(() => _logs.clear());
                                },
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(50, 24),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text('Clear', style: TextStyle(fontSize: 11)),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: () {
                                  final text = _logs.reversed.join('\n');
                                  Clipboard.setData(ClipboardData(text: text));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Logs copied to clipboard')),
                                  );
                                },
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(50, 24),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text('Copy', style: TextStyle(fontSize: 11)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        itemCount: _logs.length,
                        itemBuilder: (ctx, i) => Text(
                          _logs[i],
                          style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _discovery?.dispose();
    _transfer?.stopServer();
    super.dispose();
  }
}

class _EmptyState extends StatelessWidget {
  final bool scanning;
  final VoidCallback onRetry;

  const _EmptyState({required this.scanning, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.device_hub, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            scanning ? 'Scanning for peers…' : 'No peers found.',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (!scanning) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Scan again'),
            ),
          ],
        ],
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  final Peer peer;
  final VoidCallback onTap;

  const _PeerTile({required this.peer, required this.onTap});

  void _showDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(peer.hostname),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (peer.clientSummary != null)
              _DetailRow('Client', peer.clientSummary!),
            _DetailRow('LAN IP', peer.ip),
            if (peer.wgIp != null && peer.wgIp!.isNotEmpty)
              _DetailRow('VPN IP', peer.wgIp!),
            _DetailRow('Port', '${peer.port}'),
            _DetailRow('ID', peer.id),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(_),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isVpn = peer.wgIp != null && peer.wgIp!.isNotEmpty;
    return ListTile(
      leading: Icon(isVpn ? Icons.vpn_lock : Icons.lan),
      title: Text(peer.hostname),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (peer.clientSummary != null)
            Text(
              peer.clientSummary!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          Text(
            peer.ipSummary,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Peer details',
            onPressed: () => _showDetails(context),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _VPNHostsTab extends StatelessWidget {
  final bool available;
  final String? interfaceName;
  final String? cidr;
  final List<String> hosts;
  final String? error;
  final Peer? Function(String ip) resolvePeer;
  final TransferService? transfer;
  final Future<void> Function() onRefresh;
  final bool scanning;

  const _VPNHostsTab({
    required this.available,
    required this.interfaceName,
    required this.cidr,
    required this.hosts,
    required this.error,
    required this.resolvePeer,
    required this.transfer,
    required this.onRefresh,
    required this.scanning,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (interfaceName != null || cidr != null)
          ListTile(
            leading: const Icon(Icons.vpn_lock),
            title: Text(interfaceName ?? 'VPN'),
            subtitle: Text(cidr ?? ''),
            trailing: IconButton(
              onPressed: scanning ? null : onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          ),
        if (error != null && error!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: hosts.isEmpty
              ? Center(
                  child: Text(
                    available
                        ? 'No active VPN Peers found.'
                        : 'VPN scan did not return any usable host addresses.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : ListView.builder(
                  itemCount: hosts.length,
                  itemBuilder: (context, index) {
                    final ip = hosts[index];
                    final peer = resolvePeer(ip) ?? Peer(
                      id: ip,
                      hostname: 'VPN Peer ($ip)',
                      ip: ip,
                      wgIp: ip,
                      port: 0,
                    );
                    final linked = transfer != null;
                    return ListTile(
                      leading: Icon(linked ? Icons.vpn_lock : Icons.hub),
                      title: Text(ip),
                      subtitle: Text(
                        resolvePeer(ip)?.clientSummary ?? 'Unmatched VPN Peer',
                      ),
                      trailing: linked ? const Icon(Icons.chevron_right) : null,
                      onTap: linked
                          ? () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TransferScreen(
                                    peer: peer,
                                    transfer: transfer!,
                                  ),
                                ),
                              )
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}
