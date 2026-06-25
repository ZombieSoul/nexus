package main

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	proxy "github.com/HimbeerserverDE/mt-multiserver-proxy"
)

// =============================================================================
// Server Manager Configuration
// =============================================================================

type ServerManagerConfig struct {
	LuantiBinary  string        // path to luantiserver binary
	EngineDir     string        // path to engine directory (contains bin/)
	WorldsDir     string        // path to worlds/ directory
	ConfigDir     string        // path to config/ directory
	GameID        string        // game ID (mineclonia)

	MinPort       int           // first port for dynamic worlds (30010)
	MaxPort       int           // last port (30050)
	MaxServers    int           // max concurrent server processes
	BootTimeout   time.Duration // kill server if not online after this
	IdleTimeout   time.Duration // shut down server with 0 players after this
	ShutdownGrace time.Duration // warn players before shutting down

	APISecret     string        // shared nexus API secret
	ProxyURL      string        // nexus proxy HTTP URL (http://127.0.0.1:8090)
	MediaPool     string        // media pool name for proxy registration
}

// =============================================================================
// ManagedServer — tracks one running Luanti process
// =============================================================================

type ManagedServer struct {
	WorldName  string
	Port       int
	Cmd        *exec.Cmd
	State      string // "starting", "online", "stopping"
	StartedAt  time.Time
	PlayerCount int
	IdleSince   *time.Time
	CancelFunc  context.CancelFunc
}

// =============================================================================
// Port Pool
// =============================================================================

type PortPool struct {
	mu    sync.Mutex
	used  map[int]bool
	min   int
	max   int
}

func NewPortPool(min, max int) *PortPool {
	return &PortPool{
		used: make(map[int]bool),
		min:  min,
		max:  max,
	}
}

func (pp *PortPool) Acquire() (int, error) {
	pp.mu.Lock()
	defer pp.mu.Unlock()
	for port := pp.min; port <= pp.max; port++ {
		if !pp.used[port] {
			pp.used[port] = true
			return port, nil
		}
	}
	return 0, fmt.Errorf("no available ports in range %d-%d", pp.min, pp.max)
}

func (pp *PortPool) Release(port int) {
	pp.mu.Lock()
	defer pp.mu.Unlock()
	delete(pp.used, port)
}

func (pp *PortPool) Reserve(port int) {
	pp.mu.Lock()
	defer pp.mu.Unlock()
	pp.used[port] = true
}

// =============================================================================
// Server Manager
// =============================================================================

// ServerManager manages Luanti server process lifecycles.
// It spawns, monitors, and shuts down server processes on demand,
// enabling dialing gates on offline worlds.
type ServerManager struct {
	config   ServerManagerConfig
	registry *WorldRegistry
	universe *UniverseConfig
	ports    *PortPool

	mu       sync.RWMutex
	servers  map[string]*ManagedServer // world_name → server

	pendingLinks map[string][]chan bool // world_name → waiters for boot
	pendingMu    sync.Mutex
}

func NewServerManager(cfg ServerManagerConfig, registry *WorldRegistry, universe *UniverseConfig) *ServerManager {
	return &ServerManager{
		config:       cfg,
		registry:     registry,
		universe:     universe,
		ports:        NewPortPool(cfg.MinPort, cfg.MaxPort),
		servers:      make(map[string]*ManagedServer),
		pendingLinks: make(map[string][]chan bool),
	}
}

// Start starts the server manager's background goroutines.
func (sm *ServerManager) Start() {
	// Reserve ports used by static worlds (from proxy config)
	for name, srv := range proxy.Conf().Servers {
		if port, err := parsePortFromAddr(srv.Addr); err == nil {
			_ = name
			sm.ports.Reserve(port)
			log.Printf("[nexus] reserved port %d for static world", port)
		}
	}

	// Start idle detection loop
	go sm.idleDetectionLoop()

	// Start boot timeout checker
	go sm.bootTimeoutLoop()

	log.Printf("[nexus] server manager started (ports %d-%d, max %d servers)",
		sm.config.MinPort, sm.config.MaxPort, sm.config.MaxServers)
}

// --- World Lifecycle ---

// StartWorld spawns a Luanti server process for the given world.
// If the world is already starting or online, it's a no-op.
// Returns the assigned port, or an error.
func (sm *ServerManager) StartWorld(worldName string) (int, error) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	// Already running?
	if existing, ok := sm.servers[worldName]; ok {
		if existing.State == "online" || existing.State == "starting" {
			log.Printf("[nexus] world %s already %s", worldName, existing.State)
			return existing.Port, nil
		}
	}

	// Get world record
	world, err := sm.registry.GetWorld(worldName)
	if err != nil {
		return 0, fmt.Errorf("world %s not found in registry: %w", worldName, err)
	}

	// Check capacity
	onlineCount := sm.countOnlineServers()
	if onlineCount >= sm.config.MaxServers {
		// Try to evict an idle dynamic world
		evicted, err := sm.tryEvictLocked()
		if err != nil {
			return 0, fmt.Errorf("max servers reached (%d/%d) and no eviction candidate: %w",
				onlineCount, sm.config.MaxServers, err)
		}
		log.Printf("[nexus] evicted world %s to make room for %s", evicted, worldName)
	}

	// Acquire a port
	port, err := sm.ports.Acquire()
	if err != nil {
		return 0, fmt.Errorf("port pool exhausted: %w", err)
	}

	// Generate config file if needed
	configPath := filepath.Join(sm.config.ConfigDir, worldName+".conf")
	if err := sm.generateWorldConfig(world, port); err != nil {
		sm.ports.Release(port)
		return 0, fmt.Errorf("generate config: %w", err)
	}

	// Ensure world directory exists
	if err := os.MkdirAll(world.WorldDir, 0755); err != nil {
		sm.ports.Release(port)
		return 0, fmt.Errorf("create world dir: %w", err)
	}

	// Create world.mt if it doesn't exist
	worldMT := filepath.Join(world.WorldDir, "world.mt")
	if _, err := os.Stat(worldMT); os.IsNotExist(err) {
		content := fmt.Sprintf("gameid = %s\nbackend = sqlite3\nplayer_backend = files\nauth_backend = files\n",
			sm.config.GameID)
		if err := os.WriteFile(worldMT, []byte(content), 0644); err != nil {
			sm.ports.Release(port)
			return 0, fmt.Errorf("create world.mt: %w", err)
		}
	}

	// Create map_meta.txt if it doesn't exist
	mapMeta := filepath.Join(world.WorldDir, "map_meta.txt")
	if _, err := os.Stat(mapMeta); os.IsNotExist(err) {
		content := fmt.Sprintf("mg_name = singlenode\nseed = %d\nchunksize = 5\nwater_level = 1\nmg_flags = caves, nodungeons, light, nodecorations, biomes, ores\nmapgen_limit = 31007\nmcl_singlenode_mapgen = true\n[end_of_params]\n",
			world.Seed)
		if err := os.WriteFile(mapMeta, []byte(content), 0644); err != nil {
			sm.ports.Release(port)
			return 0, fmt.Errorf("create map_meta.txt: %w", err)
		}
	}

	// Symlink mods if not already done
	sm.ensureWorldMods(world.WorldDir)

	// Spawn the process
	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, sm.config.LuantiBinary,
		"--config", configPath,
		"--world", world.WorldDir,
		"--gameid", sm.config.GameID,
	)
	cmd.Dir = sm.config.EngineDir

	// Redirect output to log file
	logFile := fmt.Sprintf("/tmp/nexus-%s.log", worldName)
	logF, err := os.Create(logFile)
	if err != nil {
		cancel()
		sm.ports.Release(port)
		return 0, fmt.Errorf("create log file: %w", err)
	}
	cmd.Stdout = logF
	cmd.Stderr = logF

	if err := cmd.Start(); err != nil {
		logF.Close()
		cancel()
		sm.ports.Release(port)
		return 0, fmt.Errorf("start process: %w", err)
	}

	// Track the server
	ms := &ManagedServer{
		WorldName: worldName,
		Port:      port,
		Cmd:       cmd,
		State:     "starting",
		StartedAt: time.Now(),
		CancelFunc: cancel,
	}
	sm.servers[worldName] = ms

	// Update registry
	sm.registry.UpdateWorldState(worldName, "starting", port, cmd.Process.Pid)

	log.Printf("[nexus] started world %s on port %d (pid %d)",
		worldName, port, cmd.Process.Pid)

	// Monitor the process in a goroutine
	go sm.monitorProcess(worldName, cmd, logF)

	return port, nil
}

// StopWorld gracefully shuts down a world's server process.
func (sm *ServerManager) StopWorld(worldName string) error {
	sm.mu.Lock()
	ms, ok := sm.servers[worldName]
	sm.mu.Unlock()

	if !ok {
		return fmt.Errorf("world %s is not running", worldName)
	}

	if ms.State == "stopping" {
		return nil // already stopping
	}

	ms.State = "stopping"
	sm.registry.UpdateWorldState(worldName, "stopping", ms.Port, ms.Cmd.Process.Pid)

	log.Printf("[nexus] stopping world %s (pid %d)", worldName, ms.Cmd.Process.Pid)

	// Send SIGTERM for graceful shutdown
	ms.Cmd.Process.Signal(os.Interrupt)

	return nil
}

// WaitForBoot blocks until the world is online or timeout.
// Used by the link handler when dialing an offline world.
func (sm *ServerManager) WaitForBoot(worldName string, timeout time.Duration) error {
	// Check if already online
	sm.mu.RLock()
	ms, ok := sm.servers[worldName]
	sm.mu.RUnlock()

	if ok && ms.State == "online" {
		return nil
	}

	// Start the world if not already starting
	if !ok || ms.State != "starting" {
		if _, err := sm.StartWorld(worldName); err != nil {
			return err
		}
	}

	// Register a waiter
	ch := make(chan bool, 1)
	sm.pendingMu.Lock()
	sm.pendingLinks[worldName] = append(sm.pendingLinks[worldName], ch)
	sm.pendingMu.Unlock()

	// Wait for boot, timeout, or process death
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case <-ch:
		return nil
	case <-timer.C:
		return fmt.Errorf("world %s did not boot within %v", worldName, timeout)
	}
}

// notifyBootComplete wakes all waiters for a world.
func (sm *ServerManager) notifyBootComplete(worldName string, success bool) {
	sm.pendingMu.Lock()
	waiters := sm.pendingLinks[worldName]
	delete(sm.pendingLinks, worldName)
	sm.pendingMu.Unlock()

	for _, ch := range waiters {
		ch <- success
	}
}

// --- Internal: Process Monitoring ---

func (sm *ServerManager) monitorProcess(worldName string, cmd *exec.Cmd, logF *os.File) {
	// Wait for process to exit
	err := cmd.Wait()
	logF.Close()

	sm.mu.Lock()
	ms, ok := sm.servers[worldName]
	if ok {
		port := ms.Port
		sm.ports.Release(port)
		delete(sm.servers, worldName)
		sm.mu.Unlock()

		// Update registry
		sm.registry.UpdateWorldState(worldName, "offline", 0, 0)

		// Remove from proxy server list if it was a dynamic world
		world, _ := sm.registry.GetWorld(worldName)
		if world != nil && world.WorldType == "dynamic" {
			sm.unregisterFromProxy(worldName)
		}

		// Notify any waiters that boot failed
		sm.notifyBootComplete(worldName, false)

		if err != nil {
			log.Printf("[nexus] world %s process exited with error: %v", worldName, err)
		} else {
			log.Printf("[nexus] world %s process exited cleanly", worldName)
		}
	} else {
		sm.mu.Unlock()
	}
}

// --- Internal: Proxy Registration ---

// OnServerRegistered is called when a Luanti server registers its galaxy
// with the proxy via HTTP. This means the server is fully booted.
func (sm *ServerManager) OnServerRegistered(worldName string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	ms, ok := sm.servers[worldName]
	if !ok {
		return
	}

	if ms.State == "starting" {
		ms.State = "online"
		ms.IdleSince = &[]time.Time{time.Now()}[0]
		sm.registry.UpdateWorldState(worldName, "online", ms.Port, ms.Cmd.Process.Pid)
		sm.registry.UpdateWorldVisited(worldName)

		log.Printf("[nexus] world %s is now ONLINE (port %d)", worldName, ms.Port)

		// Notify waiters
		sm.notifyBootComplete(worldName, true)
	}
}

// --- Internal: Idle Detection ---

func (sm *ServerManager) idleDetectionLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		sm.mu.RLock()
		for name, ms := range sm.servers {
			if ms.State != "online" {
				continue
			}
			if ms.PlayerCount > 0 {
				ms.IdleSince = nil
				continue
			}
			if ms.IdleSince == nil {
				now := time.Now()
				ms.IdleSince = &now
				continue
			}

			idleDuration := time.Since(*ms.IdleSince)
			if idleDuration >= sm.config.IdleTimeout {
				// Check if it's a static world — don't auto-shutdown static worlds
				world, _ := sm.registry.GetWorld(name)
				if world != nil && world.WorldType == "static" {
					continue
				}

				log.Printf("[nexus] world %s idle for %v, shutting down",
					name, idleDuration)
				go sm.StopWorld(name)
			}
		}
		sm.mu.RUnlock()
	}
}

// --- Internal: Boot Timeout ---

func (sm *ServerManager) bootTimeoutLoop() {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		sm.mu.RLock()
		for name, ms := range sm.servers {
			if ms.State == "starting" && time.Since(ms.StartedAt) > sm.config.BootTimeout {
				log.Printf("[nexus] world %s boot timeout — killing process", name)
				go func(n string, ms *ManagedServer) {
					ms.CancelFunc()
				}(name, ms)
			}
		}
		sm.mu.RUnlock()
	}
}

// --- Internal: Eviction ---

// tryEvictLocked finds and shuts down the best eviction candidate.
// Caller must hold sm.mu (or accept the race — this is best-effort).
func (sm *ServerManager) tryEvictLocked() (string, error) {
	var bestCandidate string
	var oldestIdle time.Time

	for name, ms := range sm.servers {
		if ms.State != "online" || ms.PlayerCount > 0 {
			continue
		}
		world, _ := sm.registry.GetWorld(name)
		if world == nil || world.WorldType == "static" {
			continue // never evict static worlds
		}
		if ms.IdleSince != nil {
			if bestCandidate == "" || ms.IdleSince.Before(oldestIdle) {
				bestCandidate = name
				oldestIdle = *ms.IdleSince
			}
		}
	}

	if bestCandidate == "" {
		return "", fmt.Errorf("no eviction candidates")
	}

	go sm.StopWorld(bestCandidate)
	return bestCandidate, nil
}

func (sm *ServerManager) countOnlineServers() int {
	count := 0
	for _, ms := range sm.servers {
		if ms.State == "online" || ms.State == "starting" {
			count++
		}
	}
	return count
}

// --- Internal: Config Generation ---

func (sm *ServerManager) generateWorldConfig(world *WorldRecord, port int) error {
	configPath := filepath.Join(sm.config.ConfigDir, world.WorldName+".conf")

	content := fmt.Sprintf(`server_address = 127.0.0.1
port = %d
name = admin
empty_password = true
disallow_empty_password = false
secure.http_mods = nexus
language = en
default_privs = interact, shout, give

nexus.proxy_url = %s
nexus.world_name = %s
nexus.galaxy_name = %s
nexus.galaxy_tier = %d
nexus.galaxy_label = %s
nexus.world_description = %s
nexus.api_secret = %s
nexus.require_power = true

nexus_power.ores = %s
nexus_worldgen.ruin_spacing = %d
nexus_worldmanager.time_speed = %d
nexus_worldmanager.hazards = %s
`, port, sm.config.ProxyURL, world.WorldName, world.Galaxy, world.Tier,
		world.Galaxy, world.Description, sm.config.APISecret,
		world.Ores, world.RuinSpacing, world.TimeSpeed, world.Hazards)

	return os.WriteFile(configPath, []byte(content), 0644)
}

func (sm *ServerManager) ensureWorldMods(worldDir string) {
	modsDir := filepath.Join(worldDir, "worldmods")
	os.MkdirAll(modsDir, 0755)

	// Find the project's mods directory
	projectModsDir := filepath.Join(filepath.Dir(sm.config.WorldsDir), "mods")

	for _, modName := range []string{"nexus", "nexus_power", "nexus_worldgen", "nexus_worldmanager"} {
		src := filepath.Join(projectModsDir, modName)
		dst := filepath.Join(modsDir, modName)
		if _, err := os.Lstat(dst); os.IsNotExist(err) {
			os.Symlink(src, dst)
		}
	}
}

func (sm *ServerManager) unregisterFromProxy(worldName string) {
	// The proxy's config can't be modified at runtime easily,
	// but we can use AddServer/RemoveServer if available.
	// For now, we just log it — the proxy's hop mechanism handles routing.
	log.Printf("[nexus] unregistering dynamic world %s from proxy", worldName)
}

// --- Utility ---

func parsePortFromAddr(addr string) (int, error) {
	// addr format: "127.0.0.1:30000" or ":30000"
	colon := -1
	for i := len(addr) - 1; i >= 0; i-- {
		if addr[i] == ':' {
			colon = i
			break
		}
	}
	if colon == -1 {
		return 0, fmt.Errorf("no port in address: %s", addr)
	}
	return strconv.Atoi(addr[colon+1:])
}

// --- Random World Generation ---

// GenerateRandomWorld creates a new random world definition.
func (sm *ServerManager) GenerateRandomWorld(galaxyName string) (*WorldRecord, error) {
	galaxy, ok := sm.universe.Galaxies[galaxyName]
	if !ok {
		return nil, fmt.Errorf("unknown galaxy: %s", galaxyName)
	}

	// Check random world limit
	existing, err := sm.registry.ListWorldsByState("offline")
	if err == nil {
		randomCount := 0
		for _, w := range existing {
			if w.Galaxy == galaxyName && w.WorldType == "dynamic" {
				randomCount++
			}
		}
		// Also count online ones
		online, _ := sm.registry.ListWorldsByState("online")
		for _, w := range online {
			if w.Galaxy == galaxyName && w.WorldType == "dynamic" {
				randomCount++
			}
		}
		if galaxy.MaxRandomWorlds > 0 && randomCount >= galaxy.MaxRandomWorlds {
			// Pick a random existing one instead of creating new
			return sm.pickExistingRandomWorld(galaxyName)
		}
	}

	// Generate random parameters
	seed := rand.Int63()
	worldName := fmt.Sprintf("random_%d", seed%100000)
	worldDir := filepath.Join(sm.config.WorldsDir, worldName)

	// Random time speed within galaxy's range
	tsMin := galaxy.RandomParams.TimeSpeedRange[0]
	if tsMin == 0 {
		tsMin = 60
	}
	tsMax := galaxy.RandomParams.TimeSpeedRange[1]
	if tsMax == 0 {
		tsMax = 120
	}
	timeSpeed := tsMin + rand.Intn(tsMax-tsMin+1)

	// Build ore/hazard strings
	ores := ""
	for i, ore := range galaxy.RandomParams.Ores {
		if i > 0 {
			ores += ","
		}
		ores += ore
	}

	hazards := ""
	if len(galaxy.RandomParams.Hazards) > 0 {
		// Pick 0-2 random hazards
		numHazards := rand.Intn(3)
		for i := 0; i < numHazards && i < len(galaxy.RandomParams.Hazards); i++ {
			if i > 0 {
				hazards += ","
			}
			hazards += galaxy.RandomParams.Hazards[rand.Intn(len(galaxy.RandomParams.Hazards))]
		}
	}

	ruinSpacing := 32 - galaxy.Tier*4 // higher tier = more ruins
	if ruinSpacing < 8 {
		ruinSpacing = 8
	}

	world := &WorldRecord{
		WorldName:   worldName,
		Galaxy:      galaxyName,
		Tier:        galaxy.Tier,
		WorldType:   "dynamic",
		Seed:        seed,
		WorldDir:    worldDir,
		State:       "offline",
		Ores:        ores,
		Hazards:     hazards,
		TimeSpeed:   timeSpeed,
		RuinSpacing: ruinSpacing,
		Description: fmt.Sprintf("Uncharted world in %s (seed %d)", galaxy.Label, seed),
		CreatedAt:   time.Now().Unix(),
	}

	// Save to registry
	if err := sm.registry.UpsertWorld(world); err != nil {
		return nil, fmt.Errorf("save random world: %w", err)
	}

	log.Printf("[nexus] generated random world %s in %s (seed %d, ores: %s, hazards: %s)",
		worldName, galaxyName, seed, ores, hazards)

	return world, nil
}

func (sm *ServerManager) pickExistingRandomWorld(galaxyName string) (*WorldRecord, error) {
	worlds, err := sm.registry.ListWorlds()
	if err != nil {
		return nil, err
	}

	var candidates []WorldRecord
	for _, w := range worlds {
		if w.Galaxy == galaxyName && w.WorldType == "dynamic" {
			candidates = append(candidates, w)
		}
	}

	if len(candidates) == 0 {
		return nil, fmt.Errorf("no existing random worlds in %s", galaxyName)
	}

	// Pick least recently visited
	chosen := candidates[0]
	for _, c := range candidates[1:] {
		if c.LastVisited < chosen.LastVisited {
			chosen = c
		}
	}

	return &chosen, nil
}

// --- Player Count Tracking ---

// getPlayerCount returns the current player count for a world (thread-safe).
func (sm *ServerManager) getPlayerCount(worldName string) int {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	if ms, ok := sm.servers[worldName]; ok {
		return ms.PlayerCount
	}
	return 0
}

// SetPlayerCount updates the player count for a world.
// Called when players join/leave via the proxy.
func (sm *ServerManager) SetPlayerCount(worldName string, count int) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	ms, ok := sm.servers[worldName]
	if !ok {
		return
	}

	ms.PlayerCount = count
	if count == 0 && ms.IdleSince == nil {
		now := time.Now()
		ms.IdleSince = &now
	} else if count > 0 {
		ms.IdleSince = nil
	}
}

// --- Shutdown ---

// ShutdownAll stops all managed server processes.
// Called when the proxy is shutting down.
func (sm *ServerManager) ShutdownAll() {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	for name, ms := range sm.servers {
		log.Printf("[nexus] shutting down world %s", name)
		ms.State = "stopping"
		ms.Cmd.Process.Signal(os.Interrupt)
	}

	// Wait a bit for graceful shutdown
	time.Sleep(5 * time.Second)

	// Force kill any remaining
	for name, ms := range sm.servers {
		if ms.Cmd.Process != nil {
			ms.Cmd.Process.Kill()
			log.Printf("[nexus] force killed world %s", name)
		}
	}
}
