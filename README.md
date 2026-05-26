# ExtFRTC
The file transfer system using WebRTC.<br>
It can transmit files thru Local or Designated VPN IPs.<br><br>

I think this program is not attractive to most people<br>
due to the fact that the most people share their files thru cloud or Airdrop. (or Quick Share I think.)<br>
Also there is a lot of replacements in local file sharing such as Pairdrop, LocalSend.<br>
But I think the fuction they give is not quite useful<br>
due to the local restrictions.<br>
If you are using your own VPN server or if you are a homelabber,<br>
this might help because many edge devices or VMs are not in the same network. <br>
<br><br>


## Features
File Sharing<br>
Local <-> Local<br>
Local <-> VPN<br>
VPN <-> VPN<br>
is supported.<br><br>

## Requirements
> Last Update: 2026-05-26

---
### Peer Client - Native Apps
#### Android
| 항목 | 하한 | 권장 |
|------|------|------|
| **Android 버전** | Android 5.0 (API Level 21) | Android 10+ (API 29+) |
| **RAM** | 2 GB | 3 GB 이상 |
| **CPU** | ARMv7 / ARM64 / x86_64 | ARM64 |
| **저장공간** | 설치 ~50 MB + 전송 파일 임시공간 | 여유 500 MB 이상 |
| **네트워크** | Wi-Fi 802.11n | Wi-Fi 802.11ac 이상 |
| **compileSdk** | 36 | 36 |
| **NDK** | 27.0.12077973 | 27.x |

#### iOS
| 항목 | 하한 | 권장 |
|------|------|------|
| **iOS 버전** | iOS 12.0 | iOS 16+ |
| **기기** | iPhone 5s 이상 (64비트 필수) | iPhone X 이상 |
| **RAM** | 2 GB | 3 GB 이상 |
| **저장공간** | ~60 MB | — |
| **빌드 도구** | Xcode 14+ / macOS Ventura | Xcode 15+ |
| **Bundle ID** | `com.example.extfrtc` | — |

#### Windows
| 항목 | 하한 | 권장 |
|------|------|------|
| **OS 버전** | Windows 10 1903 (Build 18362) | Windows 10 21H2+ |
| **아키텍처** | x64 전용 | x64 |
| **RAM** | 4 GB | 8 GB |
| **DirectX** | DirectX 11 이상 | DirectX 12 |
| **디스크** | ~80 MB (Single Executable) | — |
| **런타임** | 번들 포함 (별도 불필요) | — |
| **네트워크** | LAN 또는 WireGuard VPN | — |

### Peer Client - Web Browser
#### Supported Browsers
| Browser | min version | status |
|---------|----------|------|
| **Chrome** | 90+ | ✅ 권장 |
| **Edge (Chromium)** | 90+ | ✅ 정상 동작 |
| **Firefox** | 78 ESR+ | ✅ DataChannel 지원 |
| **Safari** | 15.1+ | ⚠️ WebRTC 일부 제약 |
| **Samsung Internet** | 14+ | ✅ |
| IE / 구형 Edge | — | ❌ WebRTC 미지원 |

Any browser that meets the function below might work well with this binary.<br>
```
✅ WebRTC  (RTCPeerConnection + DataChannel)
✅ WebSocket
✅ Streams API
✅ Fetch API
✅ WebAssembly
✅ HTTPS or localhost  ← needs WebRTC security context
```

#### Required Hardware for Web Client
| 항목 | minimum |
|------|------|
| **RAM** | 2 GB (Including browser tabs) |
| **CPU** | Dual core 1.5 GHz 이상 |
| **Network** | Wi-Fi 802.11n / Wired 100 Mbps |
| **JS Engine** | ES2017+ (Support WebAssembly) |

### Signaling Server
|  | minimum | recommend |
|------|------|------|
| **OS** | Linux (Debian 10+ / Ubuntu 20.04+) | Ubuntu 22.04 LTS |
| **Architecture** | amd64 | amd64 / arm64 |
| **RAM** | 256 MB | 512 MB |
| **CPU** | 1 vCPU | more than 2 vCPU |
| **Disk** | ~35 MB (Integrated Binary) | 100 MB |
| **Network** | Public IP or WireGuard Interface | more than 100 Mbps |
| **Port** | 9090/tcp (Default, Can ) | — |


