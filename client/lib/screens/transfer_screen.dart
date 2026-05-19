import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/peer.dart';
import '../services/background_service.dart';
import '../services/transfer_service.dart';

class TransferScreen extends StatefulWidget {
  final Peer peer;
  final TransferService transfer;

  const TransferScreen({
    super.key,
    required this.peer,
    required this.transfer,
  });

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  String _status = 'Idle';
  bool _busy = false;

  Future<void> _pickAndSend() async {
    // withData: true ensures bytes are available on both web and native.
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null) return;
    final pf = result.files.single;
    if (pf.bytes == null) return;

    final name = pf.name;

    setState(() {
      _busy = true;
      _status = 'Connecting via WebRTC…';
    });

    // Disable background service for now to avoid signaling ID conflicts
    // await BackgroundService.start();
    // BackgroundService.updateStatus('Sending $name to ${widget.peer.hostname}');

    setState(() => _status = 'Requesting permission from ${widget.peer.hostname}…');

    final ok = await widget.transfer.sendFile(
      widget.peer,
      name,
      pf.bytes!,
      onStatusUpdate: (status) {
        if (mounted) setState(() => _status = status);
      },
    );

    // BackgroundService.stop();

    if (mounted) {
      setState(() {
        _busy = false;
        _status = ok
            ? 'Done — integrity verified (SHA-256)'
            : 'Transfer failed or hash mismatch';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Send to ${widget.peer.hostname}')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Peer info card
            Card(
              child: ListTile(
                leading: Icon(
                  widget.peer.wgIp != null ? Icons.vpn_lock : Icons.lan,
                ),
                title: Text(widget.peer.hostname),
                subtitle: Text('${widget.peer.transferAddress} · WebRTC P2P'),
              ),
            ),
            const SizedBox(height: 24),

            // Progress / status
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),

            const Spacer(),

            FilledButton.icon(
              onPressed: _busy ? null : _pickAndSend,
              icon: const Icon(Icons.upload_file),
              label: const Text('Select & Send File'),
            ),
          ],
        ),
      ),
    );
  }
}
