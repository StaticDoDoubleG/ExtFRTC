package handler

import (
	"encoding/json"
	"net/http"

	"sharemyself-server/config"
)

type rtcConfigResponse struct {
	ICEServers []config.ICEServer `json:"iceServers"`
}

func RTCConfig(cfg *config.Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(rtcConfigResponse{
			ICEServers: cfg.ICEServers,
		}); err != nil {
			http.Error(w, "encoding error", http.StatusInternalServerError)
		}
	}
}
