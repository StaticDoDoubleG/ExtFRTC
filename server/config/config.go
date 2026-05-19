package config

import (
	"os"
	"strings"
	"strconv"
	"time"
)

type Config struct {
	Addr           string
	PeerTTL        time.Duration
	ICEServers     []ICEServer
	VPNInterface   string
}

type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

func Load() *Config {
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":9090"
	}

	ttlSecs := 30
	if v := os.Getenv("PEER_TTL_SECS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			ttlSecs = n
		}
	}

	iceServers := []ICEServer{
		{
			URLs: []string{"stun:stun.l.google.com:19302"},
		},
	}

	if turnURLs := splitCSV(os.Getenv("TURN_URLS")); len(turnURLs) > 0 {
		iceServers = append(iceServers, ICEServer{
			URLs:       turnURLs,
			Username:   strings.TrimSpace(os.Getenv("TURN_USERNAME")),
			Credential: strings.TrimSpace(os.Getenv("TURN_CREDENTIAL")),
		})
	}

	return &Config{
		Addr:       addr,
		PeerTTL:    time.Duration(ttlSecs) * time.Second,
		ICEServers: iceServers,
		VPNInterface: strings.TrimSpace(os.Getenv("VPN_INTERFACE")),
	}
}

func splitCSV(raw string) []string {
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		out = append(out, part)
	}
	return out
}
