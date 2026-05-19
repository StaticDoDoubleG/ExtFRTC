package handler

import (
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"sharemyself-server/model"
)

const peerTTL = 30 * time.Second

var (
	mu    sync.RWMutex
	peers = map[string]*model.Peer{}
)

// RegisterPeer handles POST /peers/register.
// Adds or refreshes a peer entry in the in-memory store.
// If IP is empty (e.g. web clients), it is auto-detected from the request source.
func RegisterPeer(w http.ResponseWriter, r *http.Request) {
	var req model.RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.ID == "" {
		http.Error(w, "id is required", http.StatusBadRequest)
		return
	}

	ip := req.IP
	if ip == "" {
		// Web clients cannot determine their own LAN IP — detect from request source.
		if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
			ip = host
		}
	}

	mu.Lock()
	peers[req.ID] = &model.Peer{
		ID:       req.ID,
		Hostname: req.Hostname,
		IP:       ip,
		WgIP:     req.WgIP,
		Port:     req.Port,
		Platform: req.Platform,
		Client:   req.Client,
		CandidateIPs: uniqueIPs(req.CandidateIPs),
		LastSeen: time.Now(),
	}
	mu.Unlock()

	w.WriteHeader(http.StatusCreated)
}

// ListPeers handles GET /peers.
// Returns all peers that sent a heartbeat within peerTTL.
func ListPeers(w http.ResponseWriter, r *http.Request) {
	mu.RLock()
	defer mu.RUnlock()

	now := time.Now()
	active := make([]*model.Peer, 0, len(peers))
	vpnHosts := currentVPNHosts()
	for _, p := range peers {
		if now.Sub(p.LastSeen) < peerTTL {
			copyPeer := *p
			if copyPeer.WgIP == "" {
				if matched := matchVPNHost(copyPeer.CandidateIPs, vpnHosts); matched != "" {
					copyPeer.WgIP = matched
				}
			}
			active = append(active, &copyPeer)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(active); err != nil {
		http.Error(w, "encoding error", http.StatusInternalServerError)
	}
}

// Heartbeat handles POST /peers/heartbeat.
// Refreshes LastSeen so the peer stays in the active list.
func Heartbeat(w http.ResponseWriter, r *http.Request) {
	var req model.HeartbeatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	mu.Lock()
	if p, ok := peers[req.ID]; ok {
		p.LastSeen = time.Now()
	}
	mu.Unlock()

	w.WriteHeader(http.StatusOK)
}

func uniqueIPs(raw []string) []string {
	if len(raw) == 0 {
		return nil
	}
	seen := map[string]struct{}{}
	out := make([]string, 0, len(raw))
	for _, ip := range raw {
		ip = strings.TrimSpace(ip)
		if ip == "" {
			continue
		}
		if _, ok := seen[ip]; ok {
			continue
		}
		seen[ip] = struct{}{}
		out = append(out, ip)
	}
	return out
}

func matchVPNHost(candidates []string, activeHosts map[string]struct{}) string {
	for _, ip := range candidates {
		if _, ok := activeHosts[ip]; ok {
			return ip
		}
	}
	return ""
}

// MyIP handles GET /myip.
// Returns the caller's IP address as detected by the server.
// Used by web clients that cannot determine their own LAN/VPN IP.
func MyIP(w http.ResponseWriter, r *http.Request) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"ip": host})
}

// UnregisterPeer handles DELETE /peers/{id}.
// Immediately removes a peer from the store on clean shutdown.
func UnregisterPeer(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if id == "" {
		// Fallback for plain-path routing (older Go runtime compatibility).
		id = strings.TrimPrefix(r.URL.Path, "/peers/")
		id = strings.TrimSpace(id)
	}
	if id == "" {
		http.Error(w, "id is required", http.StatusBadRequest)
		return
	}

	mu.Lock()
	delete(peers, id)
	mu.Unlock()

	w.WriteHeader(http.StatusOK)
}
