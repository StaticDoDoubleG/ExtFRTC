package model

import "time"

// Peer represents a connected client node.
type Peer struct {
	ID       string    `json:"id"`
	Hostname string    `json:"hostname"`
	IP       string    `json:"ip"`    // LAN IP
	WgIP     string    `json:"wg_ip"` // WireGuard virtual IP (transfer priority)
	Port     int       `json:"port"`  // TCP port the peer listens on for file transfer
	Platform string    `json:"platform"`
	Client   string    `json:"client"`
	CandidateIPs []string `json:"candidate_ips,omitempty"`
	LastSeen time.Time `json:"last_seen"`
}

// RegisterRequest is the payload for POST /peers/register.
type RegisterRequest struct {
	ID       string `json:"id"`
	Hostname string `json:"hostname"`
	IP       string `json:"ip"`
	WgIP     string `json:"wg_ip"`
	Port     int    `json:"port"`
	Platform string `json:"platform"`
	Client   string `json:"client"`
	CandidateIPs []string `json:"candidate_ips,omitempty"`
}

// HeartbeatRequest is the payload for POST /peers/heartbeat.
type HeartbeatRequest struct {
	ID string `json:"id"`
}
