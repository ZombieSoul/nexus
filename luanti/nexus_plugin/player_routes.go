package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	proxy "github.com/HimbeerserverDE/mt-multiserver-proxy"
)

// =============================================================================
// Player Routing Handlers
// =============================================================================
// These endpoints let the void lobby check where a player was last logged in
// and trigger a hop to their destination world.

// handlePlayerRoute handles:
//   GET  /nexus/player/<name>/last_server — returns the player's last server
//   POST /nexus/player/<name>/route       — hops the player to a server
func handlePlayerRoute(w http.ResponseWriter, r *http.Request) {
	// Path: /nexus/player/<name>/<action>
	path := r.URL.Path[len("/nexus/player/"):]
	parts := strings.SplitN(path, "/", 2)
	if len(parts) < 2 {
		writeError(w, 400, "BAD_REQUEST", "Expected /nexus/player/<name>/<action>")
		return
	}

	playerName := parts[0]
	action := parts[1]

	switch action {
	case "last_server":
		handleLastServer(w, r, playerName)
	case "route":
		handleRoutePlayer(w, r, playerName)
	default:
		writeError(w, 404, "NOT_FOUND", "Unknown action: "+action)
	}
}

// handleLastServer returns the player's last connected server.
func handleLastServer(w http.ResponseWriter, r *http.Request, playerName string) {
	if r.Method != "GET" {
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use GET")
		return
	}

	// Use the proxy's auth system to read last_server
	lastSrv, err := proxy.DefaultAuth().LastSrv(playerName)
	if err != nil || lastSrv == "" {
		writeJSON(w, 200, map[string]interface{}{
			"ok":     true,
			"server": "",
		})
		return
	}

	writeJSON(w, 200, map[string]interface{}{
		"ok":     true,
		"server": lastSrv,
	})
}

// handleRoutePlayer hops a player to a specific server.
// This uses the proxy's Find + Hop API.
func handleRoutePlayer(w http.ResponseWriter, r *http.Request, playerName string) {
	if r.Method != "POST" {
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use POST")
		return
	}

	var req struct {
		Server string `json:"server"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, 400, "BAD_REQUEST", "Invalid JSON: "+err.Error())
		return
	}
	if req.Server == "" {
		writeError(w, 400, "BAD_REQUEST", "Missing 'server' field")
		return
	}

	// Find the player's connection
	cc := proxy.Find(playerName)
	if cc == nil {
		writeError(w, 404, "NOT_CONNECTED",
			fmt.Sprintf("Player '%s' is not connected", playerName))
		return
	}

	// Check if the server exists in config
	conf := proxy.Conf()
	if _, ok := conf.Servers[req.Server]; !ok {
		writeError(w, 404, "UNKNOWN_SERVER",
			fmt.Sprintf("Server '%s' not in proxy config", req.Server))
		return
	}

	// Hop the player
	if err := cc.Hop(req.Server); err != nil {
		writeError(w, 500, "HOP_FAILED", err.Error())
		return
	}

	writeJSON(w, 200, map[string]interface{}{
		"ok":     true,
		"server": req.Server,
	})
}
