// Package main is the nexus proxy plugin.
//
// nexus provides cross-server zone travel for Luanti games running behind
// mt-multiserver-proxy. It exposes an HTTP API that Lua mods use to
// transfer players (with inventory, meta, and extensible state) between
// galaxy servers.
//
// The plugin runs inside the proxy process and uses the proxy's plugin API
// (RegisterOnJoin, RegisterOnLeave, Find, ClientConn.Hop) to manage the
// transfer lifecycle.
package main

import (
	"crypto/subtle"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	proxy "github.com/HimbeerserverDE/mt-multiserver-proxy"
)

// config holds the nexus plugin configuration, loaded at startup.
var config = Config{
	APIPort:        "8080",
	APIBind:        "127.0.0.1",
	APISecret:      "", // must be set via NEXUS_API_SECRET; handlers fail closed if empty
	StorageBackend: "memory",
	ArrivalTimeout: 30 * time.Second,
	RestoreTimeout: 60 * time.Second,
	StateTTL:       5 * time.Minute,
}

// subsystems — initialized in init()
var (
	stateStore   StateStore
	transferMgr  *TransferManager
	galaxyReg    *GalaxyRegistry
	gateSys      *GateSystem
	worldReg     *WorldRegistry
	serverMgr    *ServerManager
)

func init() {
	// Load config (env vars override defaults)
	config.LoadFromEnv()

	// Initialize state store — SQLite survives proxy restart, memory does not
	var err error
	if config.StorageBackend == "sqlite" {
		stateStore, err = NewSQLiteStateStore(config.StateTTL)
		if err != nil {
			log.Println("[nexus] WARNING: SQLite state store failed, falling back to memory:", err)
			stateStore = NewMemoryStateStore(config.StateTTL)
		} else {
			log.Println("[nexus] using SQLite state store (survives restart)")
		}
	} else {
		stateStore = NewMemoryStateStore(config.StateTTL)
		log.Println("[nexus] using in-memory state store (lost on restart)")
	}

	transferMgr = NewTransferManager(stateStore, config)
	galaxyReg = NewGalaxyRegistry()
	gateSys = NewGateSystem()

	// Initialize world registry (SQLite — persists across restarts)
	worldRegPath := proxy.Path("nexus_world_registry.db")
	worldReg, err = NewWorldRegistry(worldRegPath)
	if err != nil {
		log.Println("[nexus] WARNING: world registry failed, dynamic worlds disabled:", err)
		worldReg = nil
	} else {
		log.Println("[nexus] world registry loaded (SQLite)")
		// Reset all world states to offline on startup (crash recovery)
		worldReg.ResetAllWorldStates()
	}

	// Initialize server manager if world registry is available
	if worldReg != nil {
		// Load universe config
		universePath := filepath.Join(filepath.Dir(filepath.Dir(proxy.Path(""))), "worlds.json")
		universe, err := LoadUniverseConfig(universePath)
		if err != nil {
			log.Println("[nexus] WARNING: universe config not loaded, random worlds disabled:", err)
			universe = &UniverseConfig{Galaxies: make(map[string]GalaxyConfig)}
		} else {
			// Populate static worlds from worlds.json into the registry
			// This is idempotent — running multiple times just updates the records
			universeData, _ := os.ReadFile(universePath)
			var rawWorlds struct {
				Worlds map[string]json.RawMessage `json:"worlds"`
			}
			json.Unmarshal(universeData, &rawWorlds)

			worldsDir := filepath.Join(filepath.Dir(proxy.Path("")), "worlds")
			configDir := filepath.Join(filepath.Dir(proxy.Path("")), "config")
			count := 0
			for name, raw := range rawWorlds.Worlds {
				if name == "" {
					continue
				}
				var w struct {
					Galaxy      string   `json:"galaxy"`
					GalaxyLabel string   `json:"galaxy_label"`
					Tier        int      `json:"tier"`
					Description string   `json:"description"`
					Port        int      `json:"port"`
					Mapgen      struct {
						Seed       int64 `json:"seed"`
						WaterLevel int   `json:"water_level"`
					} `json:"mapgen"`
					Ores        []string `json:"ores"`
					Ruins       struct {
						Enabled bool `json:"enabled"`
						Spacing int  `json:"spacing"`
						Tier    int  `json:"tier"`
					} `json:"ruins"`
					TimeSpeed int      `json:"time_speed"`
					Hazards   []string `json:"hazards"`
				}
				if err := json.Unmarshal(raw, &w); err != nil {
					log.Printf("[nexus] WARNING: failed to parse world %s: %v", name, err)
					continue
				}
				record := &WorldRecord{
					WorldName:   name,
					Galaxy:      w.Galaxy,
					Tier:        w.Tier,
					WorldType:   "static",
					Seed:        w.Mapgen.Seed,
					WorldDir:    filepath.Join(worldsDir, name),
					ConfigPath:  filepath.Join(configDir, name+".conf"),
					Ores:        strings.Join(w.Ores, ","),
					Hazards:     strings.Join(w.Hazards, ","),
					TimeSpeed:   w.TimeSpeed,
					RuinSpacing: w.Ruins.Spacing,
					Description: w.Description,
					CreatedAt:   time.Now().Unix(),
				}
				worldReg.UpsertWorld(record)
				count++
			}
			log.Printf("[nexus] populated %d static worlds from worlds.json", count)
		}

		engineDir := filepath.Join(filepath.Dir(proxy.Path("")), "engine")
		worldsDir := filepath.Join(filepath.Dir(proxy.Path("")), "worlds")
		configDir := filepath.Join(filepath.Dir(proxy.Path("")), "config")

		serverMgr = NewServerManager(ServerManagerConfig{
			LuantiBinary:  filepath.Join(engineDir, "bin", "luantiserver"),
			EngineDir:     engineDir,
			WorldsDir:     worldsDir,
			ConfigDir:     configDir,
			GameID:        "mineclonia",
			MinPort:       30010,
			MaxPort:       30050,
			MaxServers:    5,
			BootTimeout:   60 * time.Second,
			IdleTimeout:   5 * time.Minute,
			ShutdownGrace: 60 * time.Second,
			APISecret:     config.APISecret,
			ProxyURL:      "http://127.0.0.1:" + config.APIPort,
			MediaPool:     "mineclonia",
		}, worldReg, universe)

		serverMgr.Start()
	}

	// Register proxy lifecycle hooks
	proxy.RegisterOnJoin(onClientJoin)
	proxy.RegisterOnLeave(onClientLeave)

	// Start HTTP API in a goroutine (must not block init)
	go startHTTPServer()

	log.Println("[nexus] plugin loaded — API on", config.APIBind+":"+config.APIPort,
		"— auth:", authStatus())
}

// authStatus returns a human-readable indicator of whether API auth is armed.
func authStatus() string {
	if config.APISecret != "" {
		return "ENABLED (bearer token required)"
	}
	return "DISABLED (no NEXUS_API_SECRET set — fail-closed)"
}

// onClientJoin is called when a player connects to the proxy.
func onClientJoin(cc *proxy.ClientConn) string {
	// Update player count for the destination world
	if serverMgr != nil && cc.ServerName() != "" {
		// The player is connecting to a world — increment its count
		// We do this asynchronously to avoid blocking the join
		go func() {
			worlds, _ := worldReg.ListWorlds()
			for _, w := range worlds {
				if w.WorldName == cc.ServerName() {
					serverMgr.SetPlayerCount(w.WorldName, serverMgr.getPlayerCount(w.WorldName)+1)
					break
				}
			}
		}()
	}
	return ""
}

// onClientLeave handles disconnects — cleans up any in-flight transfers.
func onClientLeave(cc *proxy.ClientConn) {
	name := cc.Name()
	transferMgr.HandleDisconnect(name)

	// Decrement player count for the world they were on
	if serverMgr != nil {
		go func() {
			worlds, _ := worldReg.ListWorlds()
			for _, w := range worlds {
				if w.WorldName == cc.ServerName() {
					serverMgr.SetPlayerCount(w.WorldName, serverMgr.getPlayerCount(w.WorldName)-1)
					break
				}
			}
		}()
	}
}

// startHTTPServer runs the Nexus REST API.
func startHTTPServer() {
	mux := http.NewServeMux()
	mux.HandleFunc("/nexus/health", handleHealth)
	mux.HandleFunc("/nexus/depart", requireAuth(handleDepart))
	mux.HandleFunc("/nexus/state/", requireAuth(handleState))
	mux.HandleFunc("/nexus/galaxies", requireAuth(handleGalaxies))
	mux.HandleFunc("/nexus/register", requireAuth(handleRegister))
	// Gate system endpoints
	mux.HandleFunc("/nexus/gate", requireAuth(handleGateRegister))
	mux.HandleFunc("/nexus/gate/", requireAuth(handleGateAddress))
	mux.HandleFunc("/nexus/link", requireAuth(handleLink))
	mux.HandleFunc("/nexus/link/", requireAuth(handleLinkAddress))
	// Item transfer endpoints
	mux.HandleFunc("/nexus/item", requireAuth(handleItem))
	mux.HandleFunc("/nexus/item/", requireAuth(handleItemAddress))
	// World management endpoints
	mux.HandleFunc("/nexus/world", requireAuth(handleWorldList))
	mux.HandleFunc("/nexus/world/", requireAuth(handleWorldAction))
	// Glyph lookup endpoint
	mux.HandleFunc("/nexus/glyphs/lookup", requireAuth(handleGlyphLookup))
	// Player routing endpoints (for void lobby)
	mux.HandleFunc("/nexus/player/", requireAuth(handlePlayerRoute))

	addr := config.APIBind + ":" + config.APIPort
	server := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	if err := server.ListenAndServe(); err != nil {
		log.Println("[nexus] HTTP server error:", err)
	}
}

// requireAuth wraps a handler, requiring a valid Bearer token matching the
// configured APISecret. The token is the shared secret trusted by all galaxy
// servers — it proves the caller is a trusted server, not an arbitrary process.
// Uses constant-time comparison to avoid timing side channels.
// If APISecret is unset, the handler fails closed (403) for safety.
func requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if config.APISecret == "" {
			writeError(w, 403, "AUTH_NOT_CONFIGURED",
				"API secret not set on proxy — refusing to serve")
			return
		}
		auth := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(auth, prefix) {
			writeError(w, 401, "UNAUTHORIZED",
				"Missing Authorization: Bearer <token> header")
			return
		}
		token := auth[len(prefix):]
		if subtle.ConstantTimeCompare([]byte(token), []byte(config.APISecret)) != 1 {
			writeError(w, 403, "FORBIDDEN", "Invalid API token")
			return
		}
		next(w, r)
	}
}

// --- HTTP Handlers ---

// handleHealth responds to liveness checks.
func handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{
		"ok":                 true,
		"version":            "1.0",
		"players_in_transit": transferMgr.ActiveCount(),
		"galaxies":           galaxyReg.Count(),
	})
}

// handleDepart is called by the origin server's Lua mod when a player
// wants to travel. It stores the player's state and initiates the hop.
//
// POST /nexus/depart
// Body: { "player": "alice", "destination": "beta", "state": {...} }
func handleDepart(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use POST")
		return
	}

	var req DepartRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, 400, "BAD_REQUEST", "Invalid JSON: "+err.Error())
		return
	}

	if req.Player == "" || req.Destination == "" {
		writeError(w, 400, "BAD_REQUEST", "Missing 'player' or 'destination'")
		return
	}

	// Validate destination exists in proxy config
	if _, ok := proxy.Conf().Servers[req.Destination]; !ok {
		writeError(w, 404, "UNKNOWN_DESTINATION",
			"No server named '"+req.Destination+"' in proxy config")
		return
	}

	// Find the player's connection
	cc := proxy.Find(req.Player)
	if cc == nil {
		writeError(w, 503, "NOT_CONNECTED",
			"Player '"+req.Player+"' is not connected to the proxy")
		return
	}

	// Check they're not already traveling
	_, err := transferMgr.BeginTransfer(req.Player)
	if err != nil {
		writeError(w, 409, "IN_TRANSIT", err.Error())
		return
	}

	// Store the player's state
	if err := stateStore.Store(req.Player, &req.State); err != nil {
		transferMgr.FailTransfer(req.Player)
		writeError(w, 500, "STORE_FAILED", err.Error())
		return
	}

	log.Printf("[nexus] depart: %s → %s (state stored, %d bytes)",
		req.Player, req.Destination, len(req.State.Inventory))

	// Initiate the hop asynchronously
	go func() {
		if err := cc.Hop(req.Destination); err != nil {
			log.Printf("[nexus] hop failed for %s: %v", req.Player, err)
			transferMgr.FailTransfer(req.Player)
			stateStore.Delete(req.Player)
			return
		}
		transferMgr.ConfirmHop(req.Player, req.Destination)
		log.Printf("[nexus] hop confirmed: %s is now on %s", req.Player, req.Destination)
	}()

	writeJSON(w, 200, DepartResponse{
		OK:        true,
		RequestID: req.RequestID,
		Message:   "Departure initiated",
	})
}

// handleState handles GET (retrieve) and DELETE (confirm restore) for
// player state. Called by the destination server.
//
// GET /nexus/state/alice       → returns stored state
// DELETE /nexus/state/alice    → confirms restore, cleans up
func handleState(w http.ResponseWriter, r *http.Request) {
	// Extract player name from path: /nexus/state/<player>
	playerName := r.URL.Path[len("/nexus/state/"):]
	if playerName == "" {
		writeError(w, 400, "BAD_REQUEST", "Missing player name in path")
		return
	}

	switch r.Method {
	case "GET":
		state, ok := stateStore.Retrieve(playerName)
		if !ok {
			writeError(w, 404, "NO_STATE",
				"No pending state for player '"+playerName+"'")
			return
		}
		writeJSON(w, 200, map[string]any{
			"ok":    true,
			"state": state,
		})

	case "DELETE":
		stateStore.Delete(playerName)
		transferMgr.CompleteTransfer(playerName)
		log.Printf("[nexus] state restored and cleared for %s", playerName)
		writeJSON(w, 200, map[string]any{
			"ok":      true,
			"message": "State cleared",
		})

	default:
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use GET or DELETE")
	}
}

// handleGalaxies returns all known galaxies and their availability.
//
// GET /nexus/galaxies
func handleGalaxies(w http.ResponseWriter, r *http.Request) {
	galaxies := galaxyReg.All()
	// Augment with server availability from proxy config
	for _, g := range galaxies {
		_, g.Available = proxy.Conf().Servers[g.Name]
	}
	writeJSON(w, 200, map[string]any{
		"galaxies": galaxies,
	})
}

// handleRegister lets galaxy servers register their metadata at startup.
//
// POST /nexus/register
// Body: { "galaxy": { "name": "alpha", "label": "Alpha Sector", "tier": 1 } }
func handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use POST")
		return
	}

	var req struct {
		Galaxy Galaxy `json:"galaxy"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, 400, "BAD_REQUEST", "Invalid JSON: "+err.Error())
		return
	}

	galaxyReg.Register(&req.Galaxy)
	log.Printf("[nexus] galaxy registered: %s (%s, tier %d)",
		req.Galaxy.Name, req.Galaxy.Label, req.Galaxy.Tier)

	// Notify server manager that this world is online
	onGalaxyRegistered(req.Galaxy.Name)

	writeJSON(w, 200, map[string]any{
		"ok":      true,
		"message": "Galaxy registered",
	})
}

// --- Helpers ---

func writeJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{
		"ok":      false,
		"error":   code,
		"message": message,
	})
}

// Config holds nexus plugin configuration.
type Config struct {
	APIPort        string
	APIBind        string
	APISecret      string // shared bearer token trusted by all galaxy servers
	StorageBackend string
	ArrivalTimeout time.Duration
	RestoreTimeout time.Duration
	StateTTL       time.Duration
}

// LoadFromEnv reads configuration from environment variables.
func (c *Config) LoadFromEnv() {
	if v := os.Getenv("NEXUS_API_PORT"); v != "" {
		c.APIPort = v
	}
	if v := os.Getenv("NEXUS_API_BIND"); v != "" {
		c.APIBind = v
	}
	c.APISecret = os.Getenv("NEXUS_API_SECRET")
	if v := os.Getenv("NEXUS_STORAGE_BACKEND"); v != "" {
		c.StorageBackend = v
	}
}

// DepartRequest is the body of POST /nexus/depart.
type DepartRequest struct {
	Player      string `json:"player"`
	Destination string `json:"destination"`
	RequestID   string `json:"request_id"`
	State       PlayerState `json:"state"`
}

// DepartResponse is returned by POST /nexus/depart.
type DepartResponse struct {
	OK        bool   `json:"ok"`
	RequestID string `json:"request_id"`
	Message   string `json:"message"`
}

// PlayerState is the full state table that travels with a player.
// This matches the state format in nexus-api-spec.md §4.
type PlayerState struct {
	Version     int    `json:"version"`
	Format      string `json:"format"`
	Player      string `json:"player"`
	Origin      string `json:"origin"`
	Destination string `json:"destination"`
	Timestamp   int64  `json:"timestamp"`
	RequestID   string `json:"request_id"`

	// Core player attributes
	Core struct {
		HP     int `json:"hp"`
		Breath int `json:"breath"`
	} `json:"core"`

	// Serialized inventory (opaque to the plugin — Lua handles structure)
	Inventory json.RawMessage `json:"inventory"`

	// Player metadata (key-value)
	PlayerMeta map[string]string `json:"player_meta"`

	// Custom extension state from registered handlers
	Extensions map[string]json.RawMessage `json:"extensions"`

	// Gate travel info (populated when traveling via gate)
	GateTravel *GateTravelInfo `json:"gate_travel,omitempty"`
}

// GateTravelInfo tells the destination server where to place the player.
type GateTravelInfo struct {
	DepartureGate string `json:"departure_gate"`
	ArrivalGate   string `json:"arrival_gate"`
}

// Galaxy represents a registered galaxy server.
type Galaxy struct {
	Name     string `json:"name"`
	Label    string `json:"label"`
	Tier     int    `json:"tier"`
	Available bool  `json:"available"`
}

// --- Galaxy Registry ---

// GalaxyRegistry tracks galaxy metadata registered by servers.
type GalaxyRegistry struct {
	mu      sync.RWMutex
	galaxies map[string]*Galaxy
}

func NewGalaxyRegistry() *GalaxyRegistry {
	return &GalaxyRegistry{
		galaxies: make(map[string]*Galaxy),
	}
}

func (g *GalaxyRegistry) Register(galaxy *Galaxy) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.galaxies[galaxy.Name] = galaxy
}

func (g *GalaxyRegistry) All() []*Galaxy {
	g.mu.RLock()
	defer g.mu.RUnlock()
	result := make([]*Galaxy, 0, len(g.galaxies))
	for _, galaxy := range g.galaxies {
		result = append(result, galaxy)
	}
	return result
}

func (g *GalaxyRegistry) Count() int {
	g.mu.RLock()
	defer g.mu.RUnlock()
	return len(g.galaxies)
}
