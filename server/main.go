package main

import (
	"log"
	"net/http"

	"sharemyself-server/config"
	"sharemyself-server/handler"
)

// corsMiddleware adds CORS headers to every response and handles preflight
// OPTIONS requests. Using "*" allows any origin including VPN clients and
// browser-based Flutter web builds regardless of their origin.
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func main() {
	cfg := config.Load()
	vpnScanner := handler.NewVPNScanner(cfg)

	mux := http.NewServeMux()
	register := func(method, path string, h http.HandlerFunc) {
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			if r.Method != method {
				w.Header().Set("Allow", method+", OPTIONS")
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			h(w, r)
		})
	}

	// Peer lifecycle
	register(http.MethodPost, "/peers/register", handler.RegisterPeer)
	register(http.MethodPost, "/peers/heartbeat", handler.Heartbeat)
	register(http.MethodDelete, "/peers/", handler.UnregisterPeer)
	// Discovery
	register(http.MethodGet, "/peers", handler.ListPeers)
	// IP reflection — lets clients (especially web) learn their own IP
	register(http.MethodGet, "/myip", handler.MyIP)
	register(http.MethodGet, "/rtc-config", handler.RTCConfig(cfg))
	register(http.MethodGet, "/vpn/scan", vpnScanner.Handler())
	// WebRTC signaling — SDP/ICE exchange only, no file data
	register(http.MethodGet, "/signal/ws", handler.SignalWS)
	// Server streaming relay
	register(http.MethodPost, "/relay/upload", handler.RelayUpload)
	register(http.MethodGet, "/relay/download", handler.RelayDownload)

	log.Printf("ExtFRTC signaling server listening on %s", cfg.Addr)
	log.Fatal(http.ListenAndServe(cfg.Addr, corsMiddleware(mux)))
}
