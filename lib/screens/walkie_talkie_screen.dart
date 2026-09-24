// walkie_talkie_screen.dart
// Production-grade Flutter UI for Half-Duplex Push-To-Talk Walkie Talkie.

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/audio_recorder_player_service.dart';
import '../services/p2p_walkie_service.dart';

class WalkieTalkieScreen extends StatefulWidget {
  const WalkieTalkieScreen({super.key});

  @override
  State<WalkieTalkieScreen> createState() => _WalkieTalkieScreenState();
}

class _WalkieTalkieScreenState extends State<WalkieTalkieScreen>
    with SingleTickerProviderStateMixin {
  final P2PWalkieService _p2pService = P2PWalkieService();
  final AudioRecorderPlayerService _audioService = AudioRecorderPlayerService();

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Local radio state
  int _currentChannel = 1;
  String _statusMessage = "Initializing radio...";
  bool _isHoldingPTT = false;
  AudioRadioState _audioState = AudioRadioState.idle;
  List<WalkiePeer> _peersList = [];

  // Stream subscriptions
  StreamSubscription? _incomingAudioSub;
  StreamSubscription? _audioStateSub;
  StreamSubscription? _peersSub;
  StreamSubscription? _statusSub;

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _bootstrapHardware();
  }

  void _setupAnimations() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  Future<void> _bootstrapHardware() async {
    // 1. Initialize audio player and recording pipelines
    await _audioService.initialize();

    // 2. Request runtime permissions
    final hasPerms = await _p2pService.checkAndRequestPermissions();
    if (!hasPerms) {
      setState(() => _statusMessage = "Permissions required to use PTT");
      return;
    }

    // 3. Initialize P2P advertising and discovery mesh
    await _p2pService.initialize();
    await _p2pService.startDiscoveryAndBroadcast();

    // 4. Bind stream listeners
    _audioStateSub = _audioService.stateStream.listen((state) {
      if (mounted) setState(() => _audioState = state);
    });

    _peersSub = _p2pService.peersStream.listen((peers) {
      if (mounted) setState(() => _peersList = peers);
    });

    _statusSub = _p2pService.statusStream.listen((status) {
      if (mounted) setState(() => _statusMessage = status);
    });

    // 5. Connect incoming peer audio directly to playback service
    _incomingAudioSub = _p2pService.incomingAudioStream.listen((audioBytes) async {
      HapticFeedback.heavyImpact();
      await _audioService.playIncomingAudio(audioBytes);
    });
  }

  /// User holds down PTT button
  Future<void> _onPTTPressed() async {
    if (_audioState == AudioRadioState.playing) {
      // Half-duplex collision prevention: Cannot transmit while listening
      HapticFeedback.vibrate();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Channel busy! Another unit is currently transmitting."),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    HapticFeedback.mediumImpact();
    setState(() => _isHoldingPTT = true);

    try {
      await _audioService.startRecording();
    } catch (e) {
      setState(() => _isHoldingPTT = false);
    }
  }

  /// User releases PTT button -> Finalize and broadcast
  Future<void> _onPTTReleased() async {
    if (!_isHoldingPTT) return;
    setState(() => _isHoldingPTT = false);
    HapticFeedback.lightImpact();

    try {
      final Uint8List? audioBytes = await _audioService.stopAndGetAudioBytes();
      if (audioBytes != null && audioBytes.isNotEmpty) {
        // Send payload through P2P channel
        await _p2pService.broadcastAudioPayload(
          audioBytes,
          channel: _currentChannel,
        );
      }
    } catch (e) {
      debugPrint("[UI] PTT Broadcast error: $e");
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _incomingAudioSub?.cancel();
    _audioStateSub?.cancel();
    _peersSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connectedCount = _peersList.where((p) => p.status == PeerLinkStatus.connected).length;
    final isReceiving = _audioState == AudioRadioState.playing;

    return Scaffold(
      backgroundColor: const Color(0xFF121417),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E2228),
        elevation: 2,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "TACTICAL PTT WALKIE",
              style: TextStyle(
                fontFamily: "monospace",
                fontWeight: FontWeight.bold,
                fontSize: 16,
                letterSpacing: 1.2,
                color: Colors.white,
              ),
            ),
            Text(
              "Callsign: ${_p2pService.localCallsign}",
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          // Channel Selector
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: DropdownButton<int>(
              value: _currentChannel,
              dropdownColor: const Color(0xFF1E2228),
              style: const TextStyle(
                color: Color(0xFF4ADE80),
                fontWeight: FontWeight.bold,
                fontFamily: "monospace",
              ),
              underline: const SizedBox(),
              items: List.generate(8, (i) => i + 1).map((ch) {
                return DropdownMenuItem<int>(
                  value: ch,
                  child: Text("CH $ch"),
                );
              }).toList(),
              onChanged: (newCh) {
                if (newCh != null) {
                  setState(() => _currentChannel = newCh);
                  HapticFeedback.selectionClick();
                }
              },
            ),
          ),
          Builder(
            builder: (context) => IconButton(
              icon: Badge(
                label: Text("$connectedCount"),
                isLabelVisible: connectedCount > 0,
                child: const Icon(Icons.people_outline, color: Colors.white),
              ),
              onPressed: () => Scaffold.of(context).openEndDrawer(),
            ),
          ),
        ],
      ),
      endDrawer: _buildPeerDrawer(connectedCount),
      body: SafeArea(
        child: Column(
          children: [
            // Status Banner
            _buildStatusBar(connectedCount, isReceiving),

            const Spacer(),

            // Tactical Radio Display Screen
            _buildLcdDisplay(connectedCount, isReceiving),

            const Spacer(),

            // Central Push-To-Talk Button
            _buildCentralPTTButton(isReceiving),

            const Spacer(),

            // Footer instructions & security notice
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar(int connectedCount, bool isReceiving) {
    Color indicatorColor;
    String statusLabel;

    if (isReceiving) {
      indicatorColor = const Color(0xFF38BDF8); // Sky blue
      statusLabel = "INCOMING AUDIO TRANSMISSION";
    } else if (_isHoldingPTT) {
      indicatorColor = const Color(0xFFEF4444); // Red
      statusLabel = "BROADCASTING ON CHANNEL $_currentChannel";
    } else if (connectedCount > 0) {
      indicatorColor = const Color(0xFF22C55E); // Green
      statusLabel = "LINKED TO $connectedCount NEARBY PEER(S)";
    } else {
      indicatorColor = const Color(0xFFEAB308); // Amber
      statusLabel = "SCANNING FOR NEARBY UNITS...";
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: indicatorColor.withOpacity(0.12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: indicatorColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: indicatorColor.withOpacity(0.6),
                  blurRadius: 6,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              statusLabel,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: indicatorColor,
                fontWeight: FontWeight.bold,
                fontSize: 12,
                fontFamily: "monospace",
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLcdDisplay(int connectedCount, bool isReceiving) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1713),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E3A2F), width: 2),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "CH-$_currentChannel  462.5625 MHz",
                style: const TextStyle(
                  color: Color(0xFF4ADE80),
                  fontFamily: "monospace",
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              Text(
                "ENC: OFF-GRID",
                style: TextStyle(
                  color: Colors.grey[500],
                  fontFamily: "monospace",
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const Divider(color: Color(0xFF1E3A2F), height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildMetric("PEERS", "$connectedCount"),
              _buildMetric("MODE", "HALF-DUPLEX"),
              _buildMetric("CODEC", "AAC-LC"),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _statusMessage,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF86EFAC),
              fontFamily: "monospace",
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetric(String label, String value) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10, fontFamily: "monospace")),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Color(0xFF4ADE80),
            fontWeight: FontWeight.bold,
            fontSize: 14,
            fontFamily: "monospace",
          ),
        ),
      ],
    );
  }

  Widget _buildCentralPTTButton(bool isReceiving) {
    Color buttonColor;
    Color glowColor;
    String buttonText;
    IconData buttonIcon;

    if (isReceiving) {
      buttonColor = const Color(0xFF0284C7); // Blue
      glowColor = Colors.lightBlueAccent;
      buttonText = "RECEIVING";
      buttonIcon = Icons.volume_up;
    } else if (_isHoldingPTT) {
      buttonColor = const Color(0xFFDC2626); // Bright Red
      glowColor = Colors.redAccent;
      buttonText = "TRANSMITTING";
      buttonIcon = Icons.mic;
    } else {
      buttonColor = const Color(0xFF16A34A); // Tactical Green
      glowColor = Colors.greenAccent;
      buttonText = "HOLD TO TALK";
      buttonIcon = Icons.mic_none;
    }

    Widget buttonWidget = GestureDetector(
      onTapDown: (_) => _onPTTPressed(),
      onTapUp: (_) => _onPTTReleased(),
      onTapCancel: () => _onPTTReleased(),
      child: Container(
        width: 220,
        height: 220,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              buttonColor.withOpacity(0.9),
              buttonColor,
              const Color(0xFF1F2937),
            ],
            stops: const [0.4, 0.85, 1.0],
          ),
          border: Border.all(
            color: glowColor.withOpacity(0.8),
            width: _isHoldingPTT || isReceiving ? 4 : 2,
          ),
          boxShadow: [
            BoxShadow(
              color: glowColor.withOpacity(0.4),
              blurRadius: _isHoldingPTT || isReceiving ? 30 : 15,
              spreadRadius: _isHoldingPTT || isReceiving ? 8 : 2,
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(buttonIcon, size: 54, color: Colors.white),
            const SizedBox(height: 10),
            Text(
              buttonText,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
                letterSpacing: 1.5,
                fontFamily: "monospace",
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _isHoldingPTT ? "RELEASE TO SEND" : "PUSH TO TALK",
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 10,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
      ),
    );

    if (isReceiving || _isHoldingPTT) {
      return ScaleTransition(
        scale: _pulseAnimation,
        child: buttonWidget,
      );
    }

    return buttonWidget;
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        children: [
          Text(
            "NO INTERNET - NO SIM - ZERO CENTRAL SERVERS",
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: "monospace",
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Local Mesh Link over Bluetooth LE & Multipeer Wi-Fi Direct",
            style: TextStyle(color: Colors.grey[600], fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildPeerDrawer(int connectedCount) {
    return Drawer(
      backgroundColor: const Color(0xFF181B20),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF1F242C),
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "NEARBY STATIONS",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      fontFamily: "monospace",
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Connected: $connectedCount | Discovered: ${_peersList.length}",
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _peersList.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const CircularProgressIndicator(color: Color(0xFF4ADE80)),
                          const SizedBox(height: 16),
                          Text(
                            "Searching for nearby radios...",
                            style: TextStyle(color: Colors.grey[400], fontSize: 13),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _peersList.length,
                      itemBuilder: (context, index) {
                        final peer = _peersList[index];
                        final isConn = peer.status == PeerLinkStatus.connected;

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isConn ? const Color(0xFF16A34A) : Colors.grey[800],
                            child: Icon(
                              isConn ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                          title: Text(
                            peer.displayName,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            "Packets: ${peer.packetsTransferred} • ${peer.status.name.toUpperCase()}",
                            style: TextStyle(
                              color: isConn ? const Color(0xFF4ADE80) : Colors.grey,
                              fontSize: 11,
                              fontFamily: "monospace",
                            ),
                          ),
                          trailing: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isConn ? Colors.greenAccent : Colors.orangeAccent,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
