/// Represents a discovered peer node.
class Peer {
  final String id;
  final String hostname;
  final String ip;     // LAN IP (L2 source)
  final String? wgIp; // WireGuard virtual IP (L3 source, transfer priority)
  final int port;      // TCP port for file transfer
  final String? platform;
  final String? client;
  final List<String>? candidateIps;

  const Peer({
    required this.id,
    required this.hostname,
    required this.ip,
    this.wgIp,
    required this.port,
    this.platform,
    this.client,
    this.candidateIps,
  });

  /// FR-02: Prefer WireGuard IP (L3) over LAN IP (L2).
  String get transferAddress {
    final vpn = wgIp;
    if (vpn != null && vpn.isNotEmpty) {
      return vpn;
    }
    return ip;
  }

  String get primaryIpLabel => transferAddress;

  String get ipSummary {
    final vpn = wgIp;
    if (vpn != null && vpn.isNotEmpty && vpn != ip) {
      return 'VPN $vpn · LAN $ip';
    }
    return ip;
  }

  String? get clientSummary {
    final bits = <String>[
      if (platform != null && platform!.isNotEmpty) platform!,
      if (client != null && client!.isNotEmpty) client!,
    ];
    if (bits.isEmpty) return null;
    return bits.join(' · ');
  }

  Peer copyWith({
    String? hostname,
    String? ip,
    String? wgIp,
    int? port,
    String? platform,
    String? client,
    List<String>? candidateIps,
  }) {
    return Peer(
      id: id,
      hostname: hostname ?? this.hostname,
      ip: ip ?? this.ip,
      wgIp: wgIp ?? this.wgIp,
      port: port ?? this.port,
      platform: platform ?? this.platform,
      client: client ?? this.client,
      candidateIps: candidateIps ?? this.candidateIps,
    );
  }

  factory Peer.fromJson(Map<String, dynamic> json) => Peer(
        id: json['id'] as String,
        hostname: json['hostname'] as String,
        ip: json['ip'] as String,
        wgIp: json['wg_ip'] as String?,
        port: (json['port'] as num?)?.toInt() ?? 0,
        platform: json['platform'] as String?,
        client: json['client'] as String?,
        candidateIps: (json['candidate_ips'] as List<dynamic>?)
            ?.whereType<String>()
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'hostname': hostname,
        'ip': ip,
        'wg_ip': wgIp,
        'port': port,
        'platform': platform,
        'client': client,
        'candidate_ips': candidateIps,
      };

  @override
  String toString() => 'Peer($hostname @ $transferAddress:$port)';
}
