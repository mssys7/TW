# Offline Push-to-Talk (PTT) Walkie-Talkie Architecture Guide
### Cross-Platform Android & iOS Off-Grid Voice Engine
*Author: Principal Mobile Engineer*

---

## 1. System Overview & The Off-Grid Constraint
Traditional mobile voice apps (e.g. WhatsApp, Discord, Zello) rely on WebSocket/WebRTC signaling servers and cloud media relays. In contrast, this application operates under strict **Zero-Infrastructure** conditions:
- **No Internet Access:** Cellular data and Wi-Fi access points are completely disconnected.
- **No Central Coordinator:** Mesh nodes dynamically discover each other via RF beacons.
- **Half-Duplex Model:** Only one party broadcasts on a designated frequency/channel at a time.

```
+-----------------------+                    +-----------------------+
|  Node A (Transmitter)  |                    |   Node B (Receiver)   |
|                       |                    |                       |
| [Mic]                 |                    |                       |
|   | (Record AAC/Opus) |                    |                       |
| [Buffer: ~15KB]       |                    |                       |
|   |                   |                    |                       |
| [PTT Release]         |                    |                       |
|   |                   |                    |                       |
| [Packet Framer] =====>|  BLE / Wi-Fi P2P  |====> [Packet Validator] |
|                       |  Data Payload Pipe |         | (Extract)   |
|                       |  (Direct RF Link)  |    [Temp File Spool]  |
|                       |                    |         |             |
|                       |                    |    [Audio Player]     |
|                       |                    |         |             |
|                       |                    |    [Loudspeaker]      |
+-----------------------+                    +-----------------------+
```

---

## 2. Audio Pipeline & Bitrate Budgeting
The single biggest failure point in mobile P2P audio is payload size. Bluetooth LE (L2CAP / ATT) throughput is typically 40-100 kbps, while Wi-Fi Direct achieves 1-5 Mbps.

### Codec Selection:
- **Encoder:** AAC-LC (MPEG-4 Audio) or Opus.
- **Sample Rate:** 24,000 Hz (Optimal for human voice intelligibility).
- **Bitrate:** 24 kbps.
- **Channels:** Mono (1 channel).

### Bitrate Math:
$$\text{Throughput} = \frac{24,000 \text{ bps}}{8} = 3,000 \text{ Bytes/sec} \approx 2.93 \text{ KB/sec}$$

| PTT Burst Duration | Uncompressed PCM (44.1kHz, 16-bit) | Compressed AAC-LC / Opus |
| :--- | :--- | :--- |
| **3 Seconds** | 264.6 KB (Drops on BLE) | **8.8 KB** (Instant transport) |
| **5 Seconds** | 441.0 KB | **14.6 KB** (120ms transfer) |
| **10 Seconds** | 882.0 KB | **29.3 KB** (<250ms transfer) |

*Conclusion:* Compressed audio stays under 50KB for even prolonged transmissions, ensuring instantaneous delivery over low-energy radio channels without packet fragmentation crashes.

---

## 3. Binary Packet Framing Specification
Each transmission payload is framed with a 4-byte header:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   'P' (0x50)  |   'T' (0x54)  |   'T' (0x54)  | Channel (1-8) |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                    Compressed Audio Payload                   +
|                      (AAC-LC / Opus bytes)                    |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- **Bytes 0-2 (`0x50, 0x54, 0x54`):** Magic header for validation.
- **Byte 3 (`0x01 - 0x08`):** Virtual Channel / Sub-band index.
- **Bytes 4+:** Raw AAC/Opus audio bytes.

---

## 4. Platform Implementation Quirks & Workarounds

### A. Android 13+ (API 33) & Android 12 (API 31):
- Always include `android:usesPermissionFlags="neverForLocation"` in `NEARBY_WIFI_DEVICES` and `BLUETOOTH_SCAN`.
- If omitted, Android will require system Location Services (GPS) to be actively turned ON, which drains battery and blocks PTT in basements or indoors.

### B. Apple iOS Multipeer Connectivity:
- The `serviceType` in `NSBonjourServices` inside `Info.plist` MUST be prefixed with `_` and suffixed with `._tcp` and `._udp`.
- Service name length limit is strictly **1 to 15 ASCII characters**.
- iOS requires `AVAudioSessionCategory.playAndRecord` with `defaultToSpeaker` to prevent audio from routing to the earpiece.

### C. Half-Duplex Acoustic Feedback Prevention:
- If Node A is currently receiving incoming audio, the PTT button locks out recording to prevent feedback loops and channel saturation.
