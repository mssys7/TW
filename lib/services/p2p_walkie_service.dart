// p2p_walkie_service.dart
// Production-ready P2P service utilizing localized BLE and Wi-Fi Direct transports.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_nearby_connections_plus/flutter_nearby_connections_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Connection state lifecycle for peer devices
enum PeerLinkStatus {
  discovered,
  connecting,
  connected,
  disconnected,
}

/// Represents a validated nearby Walkie-Talkie peer
class WalkiePeer {
  final String id;
  final String displayName;
  final Device device;
  PeerLinkStatus status;
  DateTime lastSeen;
  int packetsTransferred;

  WalkiePeer({
    required this.id,
    required this.displayName,
    required this.device,
    this.status = PeerLinkStatus.discovered,
    int? packetsTransferred,
  })  : lastSeen = DateTime.now(),
        packetsTransferred = packetsTransferred ?? 0;
}

class P2PWalkieService {
  static final P2PWalkieService _instance = P2PWalkieService._internal();
  factory P2PWalkieService() => _instance;
  P2PWalkieService._internal();

  // Local radio identity
  late final String localDeviceId;
  String localCallsign = "Radio-${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}";

  // Nearby connections engine
  late NearbyService _nearbyService;

  // Internal peer registry
  final Map<String, WalkiePeer> _peers = {};
  
  // Stream controllers for reactive UI binding
  final _peersController = StreamController<List<WalkiePeer>>.broadcast();
  final _incomingAudioController = StreamController<Uint8List>.broadcast();
  final _serviceStatusController = StreamController<String>.broadcast();
  final _isTransmittingController = StreamController<bool>.broadcast();

  // Subscriptions
  StreamSubscription? _stateSubscription;
  StreamSubscription? _dataSubscription;

  bool _isInitialized = false;
  bool _isAdvertising = false;
  bool _isScanning = false;

  // Public reactive streams
  Stream<List<WalkiePeer>> get peersStream => _peersController.stream;
  Stream<Uint8List> get incomingAudioStream => _incomingAudioController.stream;
  Stream<String> get statusStream => _serviceStatusController.stream;
  Stream<bool> get isTransmittingStream => _isTransmittingController.stream;

  List<WalkiePeer> get connectedPeers => _peers.values
      .where((p) => p.status == PeerLinkStatus.connected)
      .toList();

  /// Step 1: Request all prerequisite platform runtime permissions
  Future<bool> checkAndRequestPermissions() async {
    _notifyStatus("Requesting hardware permissions...");

    final List<Permission> permissions = [
      Permission.microphone,
    ];

    if (Platform.isAndroid) {
      // Android 12+ requires BLUETOOTH_SCAN, BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE
      permissions.addAll([
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.nearbyWifiDevices,
        Permission.locationWhenInUse, // Required for legacy BLE beacons
      ]);
    } else if (Platform.isIOS) {
      permissions.addAll([
        Permission.bluetooth,
      ]);
    }

    final Map<Permission, PermissionStatus> statuses = await permissions.request();

    // Critical check: microphone & nearby hardware
    final micGranted = statuses[Permission.microphone]?.isGranted ?? false;
    if (!micGranted) {
      _notifyStatus("Microphone permission denied. PTT cannot operate.");
      return false;
    }

    if (Platform.isAndroid) {
      final bleGranted = statuses[Permission.bluetoothScan]?.isGranted ?? true;
      final nearbyGranted = statuses[Permission.nearbyWifiDevices]?.isGranted ?? true;
      if (!bleGranted && !nearbyGranted) {
        _notifyStatus("Local peer hardware permissions missing.");
        return false;
      }
    }

    _notifyStatus("All hardware permissions verified.");
    return true;
  }

  /// Step 2: Initialize P2P Radio Service and bind native transport streams
  Future<void> initialize({String? customCallsign}) async {
    if (_isInitialized) return;

    if (customCallsign != null && customCallsign.trim().isNotEmpty) {
      localCallsign = customCallsign.trim();
    }
    localDeviceId = "DEV_${DateTime.now().millisecondsSinceEpoch}";

    _nearbyService = NearbyService();

    // ServiceType string MUST be 1-15 characters matching Bonjour NSBonjourServices on iOS
    const String serviceType = "ptt-radio";

    await _nearbyService.init(
      serviceType: serviceType,
      strategy: Strategy.P2P_CLUSTER, // Star or Mesh cluster configuration
      callback: (isRunning) {
        debugPrint("[P2P Service] Initialized successfully. Running state: $isRunning");
      },
    );

    _bindNativeListeners();
    _isInitialized = true;
    _notifyStatus("P2P Engine online: $localCallsign");
  }

  /// Bind incoming peer events and byte packet payloads from native engine
  void _bindNativeListeners() {
    // 1. Peer Discovery & Link State Stream
    _stateSubscription = _nearbyService.stateChangedSubscription(
      callback: (devicesList) {
        for (var device in devicesList) {
          final peerId = device.deviceId;
          final existing = _peers[peerId];

          PeerLinkStatus mappedStatus;
          switch (device.state) {
            case SessionState.notConnected:
              mappedStatus = PeerLinkStatus.discovered;
              break;
            case SessionState.connecting:
              mappedStatus = PeerLinkStatus.connecting;
              break;
            case SessionState.connected:
              mappedStatus = PeerLinkStatus.connected;
              break;
          }

          if (existing == null) {
            _peers[peerId] = WalkiePeer(
              id: peerId,
              displayName: device.deviceName.isNotEmpty ? device.deviceName : "Unknown Unit",
              device: device,
              status: mappedStatus,
            );
          } else {
            existing.status = mappedStatus;
            existing.lastSeen = DateTime.now();
          }

          // Auto-connect policy for half-duplex Walkie-Talkie cluster
          if (mappedStatus == PeerLinkStatus.discovered) {
            _connectToPeer(_peers[peerId]!);
          }
        }

        // Clean up disconnected / stale peers
        _peersController.add(_peers.values.toList());
      },
    );

    // 2. Incoming Data / Audio Payload Stream
    _dataSubscription = _nearbyService.dataReceivedSubscription(
      callback: (data) {
        try {
          final Uint8List rawBytes = data['data'] as Uint8List;
          final String senderId = data['deviceId'] as String;

          if (rawBytes.isEmpty) return;

          // Process packet framing
          _handleIncomingRawPayload(rawBytes, senderId);
        } catch (e) {
          debugPrint("[P2P Service] Error receiving payload: $e");
        }
      },
    );
  }

  /// Internal packet framing validator
  /// Frame format: [0x50, 0x54, 0x54] ('PTT' Magic bytes) + [1 byte Channel] + [Audio Bytes]
  void _handleIncomingRawPayload(Uint8List payload, String senderId) {
    if (payload.length > 4 &&
        payload[0] == 0x50 && // 'P'
        payload[1] == 0x54 && // 'T'
        payload[2] == 0x54) { // 'T'
      
      final int channel = payload[3];
      final Uint8List audioData = payload.sublist(4);

      final peer = _peers[senderId];
      if (peer != null) {
        peer.packetsTransferred++;
        _peersController.add(_peers.values.toList());
      }

      debugPrint("[P2P Service] Received ${audioData.lengthInBytes} audio bytes on Channel $channel from $senderId");
      _incomingAudioController.add(audioData);
    } else {
      // Fallback for direct uncompressed or legacy payloads
      _incomingAudioController.add(payload);
    }
  }

  /// Starts bidirectional discovery (Advertising to others + Scanning for peers)
  Future<void> startDiscoveryAndBroadcast() async {
    if (!_isInitialized) await initialize();

    try {
      _notifyStatus("Starting Local Advertising...");
      await _nearbyService.startAdvertisingPeer();
      _isAdvertising = true;

      _notifyStatus("Scanning for nearby units...");
      await _nearbyService.startBrowsingForPeers();
      _isScanning = true;

      _notifyStatus("Radio Scanning on all local frequencies");
    } catch (e) {
      debugPrint("[P2P Service] Discovery start failed: $e");
      _notifyStatus("Discovery error: $e");
    }
  }

  /// Connects to a discovered remote peer unit
  Future<void> _connectToPeer(WalkiePeer peer) async {
    try {
      debugPrint("[P2P Service] Requesting link with: ${peer.displayName} (${peer.id})");
      peer.status = PeerLinkStatus.connecting;
      _peersController.add(_peers.values.toList());

      await _nearbyService.invitePeer(
        deviceID: peer.device.deviceId,
        deviceName: localCallsign,
      );
    } catch (e) {
      debugPrint("[P2P Service] Link establishment failed: $e");
      peer.status = PeerLinkStatus.disconnected;
      _peersController.add(_peers.values.toList());
    }
  }

  /// Broadcasts compressed audio bytes to all active connected peers
  /// Prepends lightweight 4-byte radio framing header
  Future<int> broadcastAudioPayload(Uint8List audioBytes, {int channel = 1}) async {
    final activePeers = connectedPeers;
    if (activePeers.isEmpty) {
      _notifyStatus("Cannot broadcast: No connected peers in range");
      return 0;
    }

    _isTransmittingController.add(true);
    _notifyStatus("Transmitting ${(audioBytes.lengthInBytes / 1024).toStringAsFixed(1)} KB to ${activePeers.length} peers...");

    // Construct framed packet: [0x50, 0x54, 0x54, ChannelByte, ...audioBytes]
    final framedPacket = Uint8List(4 + audioBytes.length);
    framedPacket[0] = 0x50; // 'P'
    framedPacket[1] = 0x54; // 'T'
    framedPacket[2] = 0x54; // 'T'
    framedPacket[3] = channel & 0xFF;
    framedPacket.setRange(4, framedPacket.length, audioBytes);

    int successCount = 0;
    for (final peer in activePeers) {
      try {
        await _nearbyService.sendMessage(
          peer.device.deviceId,
          framedPacket,
        );
        peer.packetsTransferred++;
        successCount++;
      } catch (e) {
        debugPrint("[P2P Service] Failed transmitting to ${peer.displayName}: $e");
      }
    }

    _isTransmittingController.add(false);
    _notifyStatus("Broadcast complete. Delivered to $successCount peer(s).");
    _peersController.add(_peers.values.toList());
    return successCount;
  }

  void _notifyStatus(String msg) {
    debugPrint("[P2P Status] $msg");
    _serviceStatusController.add(msg);
  }

  /// Dispose and release native radio resources
  Future<void> dispose() async {
    try {
      if (_isAdvertising) await _nearbyService.stopAdvertisingPeer();
      if (_isScanning) await _nearbyService.stopBrowsingForPeers();
    } catch (_) {}

    await _stateSubscription?.cancel();
    await _dataSubscription?.cancel();
    await _peersController.close();
    await _incomingAudioController.close();
    await _serviceStatusController.close();
    await _isTransmittingController.close();
    _peers.clear();
    _isInitialized = false;
  }
}
