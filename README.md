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

## Project State
### Client
| Program | State | - |
|------|------|------|
|**Android**| ✅ | Currently have a bug with Signaling Transfer Logic|
|**iOS**| ❌ | Not built yet due to the lack of mac |
|**Windows**| ✅ | Fully Usable |
|**Web**| ✅ | Fully Usable, Page Handler is integrated to the server binary |

### Server
The Server is
| Program | State | - |
|------|------|------|
|**Linux x64**| ✅ | Works like Charm |
|**Linux aarch64**| ⚠️ | Not Checked, might work |
|**Windows x64**| ❌ | Beta State, can be cancelled when it is not applicable |
|**Windows ARM64**| ❌ | Not currently in implementation plan |
## Requirements
> Last Update: 2026-05-26

---
### Peer Client - Native Apps
#### Android
| Requirements | Minimum | Recommend |
|------|------|------|
| **Android Version** | Android 5.0 (API Level 21) | Android 10+ (API 29+) |
| **RAM** | 2 GB | 3 GB |
| **CPU** | ARMv7 / ARM64 / x86_64 | ARM64 |
| **Storage** | Installed 50 MB + Space for Temp File(Depends on your Usage) | Over 500 MB |
| **Network** | Wi-Fi 802.11n | Wi-Fi 802.11ac |
| **compileSdk** | 36 | 36 |
| **NDK** | 27.0.12077973 | 27.x |

#### iOS
| Requirements | Minimum | Recommend |
|------|------|------|
| **iOS Version** | iOS 12.0 | iOS 16+ |
| **Device** | iPhone 5s (64bit is Necessary) | iPhone X |
| **RAM** | 2 GB | 3 GB |
| **Storage** | ~60 MB | — |
| **Build Tool** | Xcode 14+ / macOS Ventura | Xcode 15+ |
| **Bundle ID** | `com.example.extfrtc` | — |

#### Windows
| Requirements | Minimum | Recommend |
|------|------|------|
| **OS** | Windows 10 1903 (Build 18362) | Windows 10 21H2+ |
| **Architecture** | x64 | x64 |
| **RAM** | 4 GB | 8 GB |
| **DirectX** | DirectX 11 | DirectX 12 |
| **Disk** | ~80 MB (Single Executable) | — |
| **Runtime** | Included in Bundle | — |
| **Network** | LAN or WireGuard VPN | — |

### Peer Client - Web Browser
#### Supported Browsers
| Browser | Minimum Version | status |
|---------|----------|------|
| **Chrome** | 90+ | ✅ (Optimal) |
| **Edge (Chromium)** | 90+ | ✅ |
| **Firefox** | 78 ESR+ | ✅ |
| **Safari** | 15.1+ | ⚠️ has few issues in WebRTC |
| **Samsung Internet** | 14+ | ✅ |
| IE / Deperecated Edge | — | ❌ No WebRTC |

Any browser that meets the function below might work well with this binary.<br>
```
✅ WebRTC  (RTCPeerConnection + DataChannel)
✅ WebSocket
✅ Streams API
✅ Fetch API
✅ WebAssembly
✅ HTTPS or localhost  ← needs WebRTC security context
```

#### Requirements for Web Client
| Requirements | Minimum |
|------|------|
| **RAM** | 2 GB (Including browser tabs) |
| **CPU** | Dual Core 1.5 GHz |
| **Network** | Wi-Fi 802.11n / Wired 100 Mbps |
| **JS Engine** | ES2017+ (Support WebAssembly) |

### Signaling Server
| Requirements | Minimum | Recommend |
|------|------|------|
| **OS** | Linux (Debian 10+ / Ubuntu 20.04+) | Ubuntu 22.04 LTS |
| **Architecture** | amd64 | amd64 / arm64 |
| **RAM** | 256 MB | 512 MB |
| **CPU** | 1 vCPU | more than 2 vCPU |
| **Disk** | ~35 MB (Integrated Binary) | 100 MB |
| **Network** | Public IP or WireGuard Interface | over 100 Mbps |
| **Port** | 9090/tcp (Default, Can be altered) | — |


