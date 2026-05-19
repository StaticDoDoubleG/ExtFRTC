package handler

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"sharemyself-server/config"
)

const (
	maxScanHosts      = 254
	scanConcurrency   = 24
	vpnRefreshInterval = 20 * time.Second
)

type vpnScanResponse struct {
	Available    bool      `json:"available"`
	Interface    string    `json:"interface,omitempty"`
	CIDR         string    `json:"cidr,omitempty"`
	LocalIP      string    `json:"local_ip,omitempty"`
	ActiveHosts  []string  `json:"active_hosts,omitempty"`
	Error        string    `json:"error,omitempty"`
	LastUpdated  time.Time `json:"last_updated,omitempty"`
	ScanRunning  bool      `json:"scan_running"`
}

type vpnScanner struct {
	cfg   *config.Config
	mu    sync.RWMutex
	state vpnScanResponse
}

var currentScanner *vpnScanner

func NewVPNScanner(cfg *config.Config) *vpnScanner {
	s := &vpnScanner{cfg: cfg}
	s.state.Error = "VPN scan has not completed yet."
	s.state.ScanRunning = true
	currentScanner = s
	go s.loop()
	return s
}

func (s *vpnScanner) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s.mu.RLock()
		state := s.state
		s.mu.RUnlock()

		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(state)
	}
}

func (s *vpnScanner) loop() {
	for {
		s.refresh()
		time.Sleep(vpnRefreshInterval)
	}
}

func (s *vpnScanner) refresh() {
	next := vpnScanResponse{
		ScanRunning: true,
	}

	iface, network, localIP, err := detectVPNInterface(s.cfg.VPNInterface)
	if err != nil {
		next.Error = err.Error()
		s.store(next)
		return
	}

	next.Available = true
	next.Interface = iface.Name
	next.CIDR = network.String()
	next.LocalIP = localIP.String()
	next.ActiveHosts = scanSubnet(network, localIP)
	next.LastUpdated = time.Now()
	next.ScanRunning = false
	s.store(next)
}

func (s *vpnScanner) store(next vpnScanResponse) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state = next
}

func currentVPNHosts() map[string]struct{} {
	if currentScanner == nil {
		return map[string]struct{}{}
	}
	currentScanner.mu.RLock()
	defer currentScanner.mu.RUnlock()
	out := make(map[string]struct{}, len(currentScanner.state.ActiveHosts))
	for _, ip := range currentScanner.state.ActiveHosts {
		out[ip] = struct{}{}
	}
	return out
}

func detectVPNInterface(preferred string) (*net.Interface, *net.IPNet, net.IP, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, nil, nil, err
	}

	if preferred != "" {
		for _, iface := range ifaces {
			if strings.EqualFold(iface.Name, preferred) {
				ifaceCopy := iface
				return firstUsableAddr(&ifaceCopy)
			}
		}
	}

	for _, iface := range ifaces {
		if !isVPNLikeInterface(iface.Name) {
			continue
		}
		ifaceCopy := iface
		if foundIface, network, ip, err := firstUsableAddr(&ifaceCopy); err == nil {
			return foundIface, network, ip, nil
		}
	}

	for _, iface := range ifaces {
		if !looksLikePrivateTunnel(iface.Name) {
			continue
		}
		ifaceCopy := iface
		if foundIface, network, ip, err := firstUsableAddr(&ifaceCopy); err == nil {
			return foundIface, network, ip, nil
		}
	}

	return nil, nil, nil, errors.New("no active VPN-like interface found")
}

func firstUsableAddr(iface *net.Interface) (*net.Interface, *net.IPNet, net.IP, error) {
	if iface.Flags&net.FlagUp == 0 {
		return nil, nil, nil, errors.New("interface is down")
	}

	addrs, err := iface.Addrs()
	if err != nil {
		return nil, nil, nil, err
	}
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok || ipNet.IP == nil {
			continue
		}
		ip := ipNet.IP.To4()
		if ip == nil || ip.IsLoopback() {
			continue
		}
		if !isPrivateIPv4(ip) {
			continue
		}
		return iface, &net.IPNet{IP: ip.Mask(ipNet.Mask), Mask: ipNet.Mask}, ip, nil
	}
	return nil, nil, nil, errors.New("no usable private ipv4 address found")
}

func isVPNLikeInterface(name string) bool {
	lower := strings.ToLower(name)
	prefixes := []string{"wg", "tun", "tap", "ppp", "utun", "tailscale", "zt", "zerotier"}
	for _, prefix := range prefixes {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func looksLikePrivateTunnel(name string) bool {
	lower := strings.ToLower(name)
	return strings.Contains(lower, "vpn") ||
		strings.Contains(lower, "wireguard") ||
		strings.Contains(lower, "tailscale")
}

func isPrivateIPv4(ip net.IP) bool {
	privateBlocks := []string{
		"10.0.0.0/8",
		"172.16.0.0/12",
		"192.168.0.0/16",
		"100.64.0.0/10",
	}
	for _, block := range privateBlocks {
		_, subnet, err := net.ParseCIDR(block)
		if err != nil {
			continue
		}
		if subnet.Contains(ip) {
			return true
		}
	}
	return false
}

func scanSubnet(network *net.IPNet, localIP net.IP) []string {
	candidates := hostsInSubnet(network)
	if len(candidates) > maxScanHosts {
		candidates = candidates[:maxScanHosts]
	}

	jobs := make(chan string, len(candidates))
	results := make(chan string, len(candidates))

	var wg sync.WaitGroup
	for i := 0; i < scanConcurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ip := range jobs {
				if pingHost(ip) {
					results <- ip
				}
			}
		}()
	}

	local := localIP.String()
	for _, ip := range candidates {
		if ip == local {
			continue
		}
		if isLikelyGatewayAddress(ip) {
			continue
		}
		jobs <- ip
	}
	close(jobs)

	wg.Wait()
	close(results)

	active := make([]string, 0, len(results))
	for ip := range results {
		active = append(active, ip)
	}
	sort.Strings(active)
	return active
}

func hostsInSubnet(network *net.IPNet) []string {
	base := network.IP.Mask(network.Mask).To4()
	if base == nil {
		return nil
	}

	maskSize, bits := network.Mask.Size()
	if bits != 32 || maskSize > 30 {
		return nil
	}

	total := 1 << (bits - maskSize)
	hosts := make([]string, 0, total-2)
	baseInt := binary.BigEndian.Uint32(base)
	for i := 1; i < total-1; i++ {
		ip := make(net.IP, 4)
		binary.BigEndian.PutUint32(ip, baseInt+uint32(i))
		hosts = append(hosts, ip.String())
	}
	return hosts
}

func pingHost(ip string) bool {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("ping", "-n", "1", "-w", "1000", ip)
	default:
		cmd = exec.Command("ping", "-c", "1", "-W", "1", ip)
	}
	if err := cmd.Run(); err != nil {
		return false
	}
	return true
}

func isLikelyGatewayAddress(ip string) bool {
	parts := strings.Split(ip, ".")
	if len(parts) != 4 {
		return false
	}
	return parts[3] == "1"
}
