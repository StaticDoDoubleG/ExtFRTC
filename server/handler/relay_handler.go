package handler

import (
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

type relaySession struct {
	relayID    string
	to         string
	from       string
	pipeReader *io.PipeReader
	pipeWriter *io.PipeWriter
	done       chan struct{}
}

var (
	relayMu       sync.Mutex
	relaySessions = map[string]*relaySession{}
)

// RelayUpload handles POST /relay/upload?relayId=<id>&to=<to>&from=<from>
func RelayUpload(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	relayID := query.Get("relayId")
	to := query.Get("to")
	from := query.Get("from")

	if relayID == "" || to == "" || from == "" {
		fmt.Printf("[Relay] Upload request rejected: missing parameters (relayId=%s, to=%s, from=%s)\n", relayID, to, from)
		http.Error(w, "missing query parameters", http.StatusBadRequest)
		return
	}

	fmt.Printf("[Relay] Starting upload session %s (from %s to %s)\n", relayID, from, to)

	pr, pw := io.Pipe()
	session := &relaySession{
		relayID:    relayID,
		to:         to,
		from:       from,
		pipeReader: pr,
		pipeWriter: pw,
		done:       make(chan struct{}),
	}

	relayMu.Lock()
	relaySessions[relayID] = session
	relayMu.Unlock()

	defer func() {
		relayMu.Lock()
		delete(relaySessions, relayID)
		relayMu.Unlock()
		pr.Close()
		fmt.Printf("[Relay] Cleaned up session %s\n", relayID)
	}()

	// Copy from request body to pipe writer
	go func() {
		defer pw.Close()
		copied, err := io.Copy(pw, r.Body)
		if err != nil {
			fmt.Printf("[Relay] Error streaming upload for %s: %v\n", relayID, err)
		} else {
			fmt.Printf("[Relay] Upload stream copying completed: %d bytes sent to pipe for %s\n", copied, relayID)
		}
	}()

	// Wait until download is complete or request is cancelled
	select {
	case <-session.done:
		fmt.Printf("[Relay] Session %s marked done, sending 200 OK to upload client\n", relayID)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
	case <-r.Context().Done():
		fmt.Printf("[Relay] Upload client cancelled connection for %s\n", relayID)
		http.Error(w, "upload cancelled", http.StatusRequestTimeout)
	case <-time.After(1800 * time.Second): // 30 minutes timeout
		fmt.Printf("[Relay] Session %s timed out waiting for download to complete\n", relayID)
		http.Error(w, "relay timeout", http.StatusRequestTimeout)
	}
}

// RelayDownload handles GET /relay/download?relayId=<id>
func RelayDownload(w http.ResponseWriter, r *http.Request) {
	relayID := r.URL.Query().Get("relayId")
	if relayID == "" {
		http.Error(w, "missing relayId", http.StatusBadRequest)
		return
	}

	var session *relaySession
	var ok bool
	for i := 0; i < 50; i++ { // retry up to 50 times (5 seconds total)
		relayMu.Lock()
		session, ok = relaySessions[relayID]
		relayMu.Unlock()
		if ok {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	if !ok {
		fmt.Printf("[Relay] Download request rejected: session %s not found (timed out waiting for upload)\n", relayID)
		http.Error(w, "relay session not found or expired", http.StatusNotFound)
		return
	}

	fmt.Printf("[Relay] Download started for session %s (to %s)\n", relayID, session.to)

	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)

	// Copy from pipe reader to response writer
	copied, err := io.Copy(w, session.pipeReader)
	if err != nil {
		fmt.Printf("[Relay] Error streaming download for %s: %v\n", relayID, err)
	} else {
		fmt.Printf("[Relay] Download stream copying completed: %d bytes read from pipe for %s\n", copied, relayID)
	}

	close(session.done)
}
