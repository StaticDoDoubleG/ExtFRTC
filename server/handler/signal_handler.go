package handler

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	// pongWait is the maximum time to wait for the next message from the peer.
	pongWait   = 90 * time.Second
	pingPeriod = 25 * time.Second
	writeWait  = 10 * time.Second
)

var wsUpgrader = websocket.Upgrader{
	// Accept connections from any origin — peers may be on different subnets or VPNs.
	CheckOrigin: func(r *http.Request) bool { return true },
}

type signalClient struct {
	id       string
	conn     *websocket.Conn
	remoteIP string
	mu       sync.Mutex
	done     chan struct{}
}

func markDone(ch chan struct{}) {
	select {
	case <-ch:
		return
	default:
		close(ch)
	}
}

// writeJSON sends a message to the client.
func (c *signalClient) writeJSON(v any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
	return c.conn.WriteJSON(v)
}

func (c *signalClient) writePing() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn.WriteControl(
		websocket.PingMessage,
		[]byte("k"),
		time.Now().Add(writeWait),
	)
}

var (
	hubMu sync.RWMutex
	hub   = map[string]*signalClient{}
)

// SignalWS handles GET /signal/ws.
//
// Each peer identifies itself once with a "join" message, then sends "offer",
// "answer", or "ice" messages addressed to another peer by ID. The server
// only relays these small SDP/ICE control frames — file bytes never pass
// through here; they travel directly between peers via RTCDataChannel (P2P).
func SignalWS(w http.ResponseWriter, r *http.Request) {
	conn, err := wsUpgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf(
			"[signal] upgrade failed remote=%s host=%s origin=%s err=%v",
			r.RemoteAddr,
			r.Host,
			r.Header.Get("Origin"),
			err,
		)
		return
	}
	defer conn.Close()
	conn.SetReadLimit(2 << 20) // 2 MiB max signaling frame

	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if host == "" {
		host = r.RemoteAddr
	}
	if host == "127.0.0.1" || host == "::1" || host == "localhost" {
		if lanIP := getLocalIP(); lanIP != "" {
			host = lanIP
		}
	}
	client := &signalClient{conn: conn, remoteIP: host, done: make(chan struct{})}

	// Set read deadline to detect stale connections
	_ = conn.SetReadDeadline(time.Now().Add(pongWait))
	conn.SetPongHandler(func(string) error {
		_ = conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})
	conn.SetPingHandler(func(appData string) error {
		_ = conn.SetReadDeadline(time.Now().Add(pongWait))
		client.mu.Lock()
		defer client.mu.Unlock()
		return conn.WriteControl(
			websocket.PongMessage,
			[]byte(appData),
			time.Now().Add(writeWait),
		)
	})

	stopPing := make(chan struct{})
	defer close(stopPing)
	go func() {
		t := time.NewTicker(pingPeriod)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				if err := client.writePing(); err != nil {
					return
				}
			case <-stopPing:
				return
			}
		}
	}()

	var self *signalClient
	joined := false

	for {
		// Keep envelope as raw JSON so it can be forwarded without a full decode/re-encode.
		var envelope map[string]json.RawMessage
		if err := conn.ReadJSON(&envelope); err != nil {
			if websocket.IsCloseError(
				err,
				websocket.CloseNormalClosure,
				websocket.CloseGoingAway,
				websocket.CloseNoStatusReceived,
			) {
				log.Printf("[signal] read closed: %v", err)
			} else {
				log.Printf("[signal] read error: %v", err)
			}
			break
		}
		// Reset deadline on any message
		_ = conn.SetReadDeadline(time.Now().Add(pongWait))

		var msgType string
		if raw, ok := envelope["type"]; !ok {
			continue
		} else if err := json.Unmarshal(raw, &msgType); err != nil {
			continue
		}

		switch msgType {
		case "ping":
			// Respond to app-level pings to keep connection alive
			if self != nil {
				if err := self.writeJSON(map[string]string{"type": "pong"}); err != nil {
					log.Printf("[signal] pong write error: %v", err)
					break
				}
			}
			continue

		case "join":
			var id string
			if raw, ok := envelope["id"]; !ok {
				continue
			} else if err := json.Unmarshal(raw, &id); err != nil || id == "" {
				continue
			}
			client.id = id
			self = client

			if raw, ok := envelope["manualIp"]; ok {
				var manualIp string
				if err := json.Unmarshal(raw, &manualIp); err == nil && manualIp != "" {
					self.remoteIP = manualIp // Override SNAT IP with the manual IP
				}
			}

			joined = true
			hubMu.Lock()
			if prev, exists := hub[id]; exists && prev != self {
				markDone(prev.done)
				_ = prev.conn.Close()
			}
			hub[id] = self
			hubMu.Unlock()
			log.Printf("[signal] + %s", id)
			if err := self.writeJSON(map[string]string{
				"type": "joined",
				"id":   id,
			}); err != nil {
				log.Printf("[signal] join ack write error to %s: %v", id, err)
				break
			}

		case "offer", "answer", "ice", "request", "accept", "decline", "relay_fallback":
			if !joined || self == nil || self.id == "" {
				_ = client.writeJSON(map[string]string{
					"type":  "error",
					"error": "join_required",
				})
				continue
			}
			var to string
			if raw, ok := envelope["to"]; !ok {
				continue
			} else if err := json.Unmarshal(raw, &to); err != nil || to == "" {
				continue
			}
			hubMu.RLock()
			target, ok := hub[to]
			if !ok {
				for _, c := range hub {
					if c.remoteIP == to {
						target = c
						ok = true
						break
					}
				}
			}
			hubMu.RUnlock()
			if ok {
				// Inject the sender's remote IP into the message so the receiver
				// can use it to patch mDNS (.local) ICE candidates over VPNs.
				envelope["senderIp"] = json.RawMessage(`"` + self.remoteIP + `"`)

				if err := target.writeJSON(envelope); err != nil {
					hubMu.Lock()
					if hub[to] == target {
						delete(hub, to)
					}
					hubMu.Unlock()
					_ = target.conn.Close()
					log.Printf("[signal] relay write error to %s: %v", to, err)
				}
			}
		}
	}

	// Peer disconnected — remove from hub.
	if self != nil {
		hubMu.Lock()
		if hub[self.id] == self {
			delete(hub, self.id)
		}
		hubMu.Unlock()
		select {
		case <-self.done:
			log.Printf("[signal] replaced %s", self.id)
		default:
			log.Printf("[signal] - %s", self.id)
		}
	}
}

// getLocalIP returns the non-loopback local IPv4 address of the host machine.
func getLocalIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	for _, address := range addrs {
		if ipnet, ok := address.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ipnet.IP.To4() != nil {
				return ipnet.IP.String()
			}
		}
	}
	return ""
}
