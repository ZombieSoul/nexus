package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"

	proxy "github.com/HimbeerserverDE/mt-multiserver-proxy"
)

// =============================================================================
// World Management HTTP Handlers
// =============================================================================

// handleWorldList handles GET /nexus/world — list all worlds
func handleWorldList(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use GET")
		return
	}
	if worldReg == nil {
		writeError(w, 503, "UNAVAILABLE", "World registry not available")
		return
	}

	worlds, err := worldReg.ListWorlds()
	if err != nil {
		writeError(w, 500, "DB_ERROR", err.Error())
		return
	}

	result := make([]map[string]interface{}, 0, len(worlds))
	for _, world := range worlds {
		result = append(result, map[string]interface{}{
			"name":         world.WorldName,
			"galaxy":       world.Galaxy,
			"tier":         world.Tier,
			"type":         world.WorldType,
			"state":        world.State,
			"port":         world.Port,
			"description":  world.Description,
			"ores":         world.Ores,
			"hazards":      world.Hazards,
			"visit_count":  world.VisitCount,
		})
	}

	writeJSON(w, 200, map[string]interface{}{
		"ok":     true,
		"worlds": result,
		"count":  len(result),
	})
}

// handleWorldAction handles /nexus/world/<name> and /nexus/world/<name>/<action>
func handleWorldAction(w http.ResponseWriter, r *http.Request) {
	if worldReg == nil {
		writeError(w, 503, "UNAVAILABLE", "World registry not available")
		return
	}

	path := r.URL.Path[len("/nexus/world/"):]
	parts := strings.SplitN(path, "/", 2)
	worldName := parts[0]
	if worldName == "" {
		writeError(w, 400, "BAD_REQUEST", "Missing world name")
		return
	}

	// Check for action suffix: /nexus/world/<name>/start, /stop, /info
	action := ""
	if len(parts) > 1 {
		action = parts[1]
	}

	switch {
	case action == "start" && r.Method == "POST":
		handleWorldStart(w, r, worldName)
	case action == "stop" && r.Method == "POST":
		handleWorldStop(w, r, worldName)
	case action == "generate" && r.Method == "POST":
		handleWorldGenerate(w, r)
	case action == "" && r.Method == "GET":
		handleWorldGet(w, r, worldName)
	default:
		if action == "" {
			writeError(w, 405, "METHOD_NOT_ALLOWED", "Use GET for info, POST with /start or /stop")
		} else {
			writeError(w, 404, "NOT_FOUND", "Unknown action: "+action)
		}
	}
}

func handleWorldGet(w http.ResponseWriter, r *http.Request, worldName string) {
	world, err := worldReg.GetWorld(worldName)
	if err != nil {
		writeError(w, 404, "NOT_FOUND", "World not found: "+worldName)
		return
	}

	// Include process info if running
	processInfo := map[string]interface{}{}
	if serverMgr != nil {
		serverMgr.mu.RLock()
		if ms, ok := serverMgr.servers[worldName]; ok {
			processInfo = map[string]interface{}{
				"state":        ms.State,
				"pid":          ms.Cmd.Process.Pid,
				"player_count": ms.PlayerCount,
				"started_at":   ms.StartedAt.Unix(),
			}
			if ms.IdleSince != nil {
				processInfo["idle_since"] = ms.IdleSince.Unix()
			}
		}
		serverMgr.mu.RUnlock()
	}

	writeJSON(w, 200, map[string]interface{}{
		"ok":     true,
		"world":  world,
		"process": processInfo,
	})
}

func handleWorldStart(w http.ResponseWriter, r *http.Request, worldName string) {
	if serverMgr == nil {
		writeError(w, 503, "UNAVAILABLE", "Server manager not available")
		return
	}

	// Check if this is a static world (always running, managed by startup script)
	// These are in the proxy's config.json and don't need process management.
	if _, exists := proxy.Conf().Servers[worldName]; exists {
		writeJSON(w, 200, map[string]interface{}{
			"ok":    true,
			"world": worldName,
			"state": "online",
		})
		return
	}

	// Check if already running as a managed server
	serverMgr.mu.RLock()
	ms, exists := serverMgr.servers[worldName]
	serverMgr.mu.RUnlock()

	if exists && (ms.State == "online" || ms.State == "starting") {
		writeJSON(w, 200, map[string]interface{}{
			"ok":    true,
			"world": worldName,
			"port":  ms.Port,
			"state": ms.State,
		})
		return
	}

	port, err := serverMgr.StartWorld(worldName)
	if err != nil {
		writeError(w, 500, "START_FAILED", err.Error())
		return
	}

	writeJSON(w, 200, map[string]interface{}{
		"ok":    true,
		"world": worldName,
		"port":  port,
		"state": "starting",
	})
}

func handleWorldStop(w http.ResponseWriter, r *http.Request, worldName string) {
	if serverMgr == nil {
		writeError(w, 503, "UNAVAILABLE", "Server manager not available")
		return
	}

	if err := serverMgr.StopWorld(worldName); err != nil {
		writeError(w, 500, "STOP_FAILED", err.Error())
		return
	}

	writeJSON(w, 200, map[string]interface{}{
		"ok":    true,
		"world": worldName,
		"state": "stopping",
	})
}

func handleWorldGenerate(w http.ResponseWriter, r *http.Request) {
	if serverMgr == nil {
		writeError(w, 503, "UNAVAILABLE", "Server manager not available")
		return
	}

	var req struct {
		Galaxy string `json:"galaxy"`
	}
	if r.Body != nil {
		json.NewDecoder(r.Body).Decode(&req)
	}
	if req.Galaxy == "" {
		writeError(w, 400, "BAD_REQUEST", "Missing 'galaxy' field")
		return
	}

	world, err := serverMgr.GenerateRandomWorld(req.Galaxy)
	if err != nil {
		writeError(w, 500, "GENERATE_FAILED", err.Error())
		return
	}

	writeJSON(w, 200, map[string]interface{}{
		"ok":    true,
		"world": world,
	})
}

// =============================================================================
// Galaxy Registration Hook
// =============================================================================
// When a Luanti server registers its galaxy via POST /nexus/register,
// we notify the server manager that the world is online.

// onGalaxyRegistered is called after a successful galaxy registration.
// It tells the server manager that the world's server has fully booted.
func onGalaxyRegistered(galaxyName string) {
	if serverMgr == nil || worldReg == nil {
		return
	}

	// Find which world this galaxy registration came from.
	// We check all worlds in this galaxy that are in "starting" state.
	starting, err := worldReg.ListWorldsByState("starting")
	if err != nil {
		return
	}

	for _, world := range starting {
		if world.Galaxy == galaxyName {
			log.Printf("[nexus] galaxy %s registered — world %s is online",
				galaxyName, world.WorldName)
			serverMgr.OnServerRegistered(world.WorldName)
			return
		}
	}

	// For static worlds that are already in the startup script,
	// they don't go through the server manager. That's fine —
	// we only track dynamic/managed worlds.
}

// Wire galaxy registration to server manager
// (called from the existing handleRegister function)
