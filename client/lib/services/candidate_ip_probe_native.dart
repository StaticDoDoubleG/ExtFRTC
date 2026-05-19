import 'dart:io';

class CandidateIpProbe {
  static Future<List<String>> collect() async {
    final seen = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) {
            continue;
          }
          final ip = addr.address;
          if (_isPrivateIPv4(ip)) {
            seen.add(ip);
          }
        }
      }
    } catch (_) {}
    final out = seen.toList()..sort();
    return out;
  }

  static bool _isPrivateIPv4(String ip) {
    return ip.startsWith('10.') ||
        ip.startsWith('192.168.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(ip) ||
        RegExp(r'^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.').hasMatch(ip);
  }
}
