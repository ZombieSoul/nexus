package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Vec3 is a 3D vector used for positions and offsets.
type Vec3 struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	Z float64 `json:"z"`
}

// Gate represents a physical stargate registered with the proxy.
// The proxy is the source of truth for gate existence and link state.
type Gate struct {
	Address       string `json:"address"`
	Label         string `json:"label"`
	Galaxy        string `json:"galaxy"`
	World         string `json:"world"`
	Position      Vec3   `json:"position"`
	ArrivalOffset Vec3   `json:"arrival_offset"`
	Facing        int    `json:"facing"` // yaw in degrees
	Powered       bool   `json:"powered"`
	Obstructed    bool   `json:"obstructed"`
	RegisteredAt  int64  `json:"registered_at"`
}

// GateLink represents an active wormhole between two gates.
type GateLink struct {
	LinkID    string `json:"link_id"`
	GateA     string `json:"gate_a"` // origin gate (who dialed)
	GateB     string `json:"gate_b"` // destination gate
	Direction string `json:"direction"`
	OpenedBy  string `json:"opened_by"`
	OpenedAt  int64  `json:"opened_at"`
	ExpiresAt int64  `json:"expires_at"` // 0 = manual close only
	State     string `json:"state"`      // "active", "closed"
}

// QueuedItem is an item waiting to be fetched by the destination gate's server.
type QueuedItem struct {
	Item      map[string]any `json:"item"`
	Velocity  Vec3           `json:"velocity"`
	Owner     string         `json:"owner"`
	EntryGate string         `json:"entry_gate"`
	QueuedAt  int64          `json:"queued_at"`
}

// GateSystem manages the gate registry and link state.
// It is the central authority — galaxy servers query it to validate
// destinations and learn arrival positions.
type GateSystem struct {
	mu    sync.RWMutex
	gates map[string]*Gate     // keyed by address
	links map[string]*GateLink // keyed by link_id
	items map[string][]QueuedItem // keyed by destination gate address
}

func NewGateSystem() *GateSystem {
	gs := &GateSystem{
		gates: make(map[string]*Gate),
		links: make(map[string]*GateLink),
		items: make(map[string][]QueuedItem),
	}
	go gs.cleanupLoop()
	return gs
}

// --- Gate Registry ---

func (gs *GateSystem) Register(gate *Gate) {
	gs.mu.Lock()
	defer gs.mu.Unlock()
	gate.RegisteredAt = time.Now().Unix()
	gs.gates[gate.Address] = gate
	log.Printf("[nexus] gate registered: %s (%s, galaxy %s, pos %.0f,%.0f,%.0f)",
		gate.Address, gate.Label, gate.Galaxy,
		gate.Position.X, gate.Position.Y, gate.Position.Z)
}

func (gs *GateSystem) Unregister(address string) *GateLink {
	gs.mu.Lock()
	defer gs.mu.Unlock()
	if _, ok := gs.gates[address]; !ok {
		return nil
	}
	delete(gs.gates, address)
	// Break any active link involving this gate
	broken := gs.breakLinksForGateLocked(address)
	log.Printf("[nexus] gate unregistered: %s", address)
	return broken
}

func (gs *GateSystem) Get(address string) (*Gate, bool) {
	gs.mu.RLock()
	defer gs.mu.RUnlock()
	g, ok := gs.gates[address]
	return g, ok
}

func (gs *GateSystem) UpdateState(address string, powered *bool, obstructed *bool) bool {
	gs.mu.Lock()
	defer gs.mu.Unlock()
	g, ok := gs.gates[address]
	if !ok {
		return false
	}
	if powered != nil {
		g.Powered = *powered
	}
	if obstructed != nil {
		g.Obstructed = *obstructed
	}
	return true
}

// --- Link Management ---

// Establish creates a link between two gates after validation.
// Returns the link on success, or an error code/message on failure.
func (gs *GateSystem) Establish(from, to, openedBy string, duration int) (*GateLink, string, string) {
	gs.mu.Lock()
	defer gs.mu.Unlock()

	// Validate destination exists
	destGate, ok := gs.gates[to]
	if !ok {
		return nil, "UNREACHABLE", fmt.Sprintf("No gate at address '%s'", to)
	}
	_ = destGate

	// Validate origin exists
	if _, ok := gs.gates[from]; !ok {
		return nil, "UNREACHABLE", fmt.Sprintf("No gate at address '%s'", from)
	}

	// Can't link to self
	if from == to {
		return nil, "INVALID", "Gate cannot link to itself"
	}

	// Check destination is powered
	if !destGate.Powered {
		return nil, "UNPOWERED", "Destination gate has no power"
	}

	// Check neither gate is already linked
	if link := gs.findLinkLocked(from); link != nil {
		return nil, "BUSY", "Origin gate already linked"
	}
	if link := gs.findLinkLocked(to); link != nil {
		return nil, "BUSY", "Destination gate already linked"
	}

	// Create the link
	now := time.Now().Unix()
	link := &GateLink{
		LinkID:    fmt.Sprintf("lnk_%d", now),
		GateA:     from,
		GateB:     to,
		Direction: "bidirectional",
		OpenedBy:  openedBy,
		OpenedAt:  now,
		ExpiresAt: 0,
		State:     "active",
	}
	if duration > 0 {
		link.ExpiresAt = now + int64(duration)
	}
	gs.links[link.LinkID] = link

	log.Printf("[nexus] link established: %s <-> %s (by %s)", from, to, openedBy)
	return link, "", ""
}

// Close breaks the link involving the given gate address.
func (gs *GateSystem) Close(gateAddress string) *GateLink {
	gs.mu.Lock()
	defer gs.mu.Unlock()
	return gs.breakLinksForGateLocked(gateAddress)
}

// GetLink returns the active link for a gate, or nil.
func (gs *GateSystem) GetLink(gateAddress string) *GateLink {
	gs.mu.RLock()
	defer gs.mu.RUnlock()
	return gs.findLinkLocked(gateAddress)
}

// findLinkLocked returns the active link for a gate (caller holds lock).
func (gs *GateSystem) findLinkLocked(gateAddress string) *GateLink {
	for _, link := range gs.links {
		if link.State != "active" {
			continue
		}
		if link.GateA == gateAddress || link.GateB == gateAddress {
			return link
		}
	}
	return nil
}

// breakLinksForGateLocked closes all active links involving a gate.
// Returns the broken link (if any) so callers can notify the partner.
func (gs *GateSystem) breakLinksForGateLocked(gateAddress string) *GateLink {
	for _, link := range gs.links {
		if link.State != "active" {
			continue
		}
		if link.GateA == gateAddress || link.GateB == gateAddress {
			link.State = "closed"
			partner := link.GateB
			if gateAddress == link.GateB {
				partner = link.GateA
			}
			log.Printf("[nexus] link broken: %s <-> %s (gate %s removed)",
				link.GateA, link.GateB, gateAddress)
			_ = partner
			return link
		}
	}
	return nil
}

// --- Item Queue ---

// QueueItem adds an item to a destination gate's pending queue.
func (gs *GateSystem) QueueItem(destGate string, item QueuedItem) {
	gs.mu.Lock()
	defer gs.mu.Unlock()
	item.QueuedAt = time.Now().Unix()
	gs.items[destGate] = append(gs.items[destGate], item)
}

// FetchItems returns all queued items for a gate and clears the queue.
func (gs *GateSystem) FetchItems(gateAddress string) []QueuedItem {
	gs.mu.Lock()
	defer gs.mu.Unlock()
	items := gs.items[gateAddress]
	delete(gs.items, gateAddress)
	return items
}

// cleanupLoop periodically removes closed links and expired item queues
// to prevent memory leaks from abandoned transfers and broken links.
func (gs *GateSystem) cleanupLoop() {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		gs.mu.Lock()
		now := time.Now().Unix()

		// Remove closed links older than 5 minutes (keep briefly for queries)
		for id, link := range gs.links {
			if link.State == "closed" && now-link.OpenedAt > 300 {
				delete(gs.links, id)
			}
			// Also remove links whose gates no longer exist
			if link.State == "active" {
				_, aExists := gs.gates[link.GateA]
				_, bExists := gs.gates[link.GateB]
				if !aExists || !bExists {
					link.State = "closed"
					log.Printf("[nexus] cleanup: breaking orphaned link %s <-> %s",
						link.GateA, link.GateB)
				}
			}
		}

		// Remove item queues for gates that no longer exist, or items older than 5 min
		for gate, items := range gs.items {
			if _, exists := gs.gates[gate]; !exists {
				if len(items) > 0 {
					log.Printf("[nexus] cleanup: discarding %d orphaned items for removed gate %s",
						len(items), gate)
				}
				delete(gs.items, gate)
			} else {
				// Filter out items older than 5 minutes
				fresh := items[:0]
				for _, item := range items {
					if now-item.QueuedAt < 300 {
						fresh = append(fresh, item)
					}
				}
				if len(fresh) == 0 {
					delete(gs.items, gate)
				} else {
					gs.items[gate] = fresh
				}
			}
		}

		gs.mu.Unlock()
	}
}

// --- HTTP Handlers ---

// handleGateRegister handles POST /nexus/gate (register/update a gate)
func handleGateRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use POST")
		return
	}
	var gate Gate
	if err := json.NewDecoder(r.Body).Decode(&gate); err != nil {
		writeError(w, 400, "BAD_REQUEST", "Invalid JSON: "+err.Error())
		return
	}
	if gate.Address == "" || gate.Galaxy == "" {
		writeError(w, 400, "BAD_REQUEST", "Missing 'address' or 'galaxy'")
		return
	}
	gateSys.Register(&gate)
	writeJSON(w, 200, map[string]any{"ok": true, "address": gate.Address})
}

// handleGateAddress handles GET/DELETE /nexus/gate/<address>
// and POST /nexus/gate/<address>/state (power/obstruction updates)
func handleGateAddress(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path[len("/nexus/gate/"):]

	// Check for /state suffix (gate state update via POST)
	if len(path) > 6 && path[len(path)-6:] == "/state" {
		address := path[:len(path)-6]
		if r.Method != "POST" {
			writeError(w, 405, "METHOD_NOT_ALLOWED", "Use POST for state updates")
			return
		}
		var update struct {
			Powered    *bool `json:"powered"`
			Obstructed *bool `json:"obstructed"`
		}
		if err := json.NewDecoder(r.Body).Decode(&update); err != nil {
			writeError(w, 400, "BAD_REQUEST", "Invalid JSON: "+err.Error())
			return
		}
		if !gateSys.UpdateState(address, update.Powered, update.Obstructed) {
			writeError(w, 404, "NOT_FOUND", "No gate at address '"+address+"'")
			return
		}
		writeJSON(w, 200, map[string]any{"ok": true, "address": address})
		return
	}

	address := path
	if address == "" {
		writeError(w, 400, "BAD_REQUEST", "Missing gate address in path")
		return
	}

	switch r.Method {
	case "GET":
		gate, ok := gateSys.Get(address)
		if !ok {
			writeError(w, 404, "NOT_FOUND", "No gate at address '"+address+"'")
			return
		}
		// Include link info
		link := gateSys.GetLink(address)
		resp := map[string]any{
			"ok":   true,
			"gate": gate,
		}
		if link != nil {
			partner := link.GateB
			if address == link.GateB {
				partner = link.GateA
			}
			resp["linked"] = true
			resp["link_partner"] = partner
		} else {
			resp["linked"] = false
		}
		writeJSON(w, 200, resp)

	case "DELETE":
		broken := gateSys.Unregister(address)
		writeJSON(w, 200, map[string]any{
			"ok":           true,
			"address":      address,
			"link_broken":  broken != nil,
		})

	default:
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use GET or DELETE")
	}
}

// handleLink handles POST /nexus/link (establish a link)
func handleLink(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use POST")
		return
	}
	var req struct {
		From     string `json:"from"`
		To       string `json:"to"`
		OpenedBy string `json:"opened_by"`
		Duration int    `json:"duration"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, 400, "BAD_REQUEST", "Invalid JSON: "+err.Error())
		return
	}
	if req.From == "" || req.To == "" {
		writeError(w, 400, "BAD_REQUEST", "Missing 'from' or 'to'")
		return
	}

	link, errCode, errMsg := gateSys.Establish(req.From, req.To, req.OpenedBy, req.Duration)
	if link == nil {
		status := 409 // conflict for BUSY, UNPOWERED etc.
		if errCode == "UNREACHABLE" {
			status = 404
		}
		writeError(w, status, errCode, errMsg)
		return
	}
	writeJSON(w, 200, map[string]any{
		"ok":      true,
		"link_id": link.LinkID,
		"state":   link.State,
	})
}

// handleLinkAddress handles GET/DELETE /nexus/link/<gate_address>
func handleLinkAddress(w http.ResponseWriter, r *http.Request) {
	gateAddress := r.URL.Path[len("/nexus/link/"):]
	if gateAddress == "" {
		writeError(w, 400, "BAD_REQUEST", "Missing gate address in path")
		return
	}

	switch r.Method {
	case "GET":
		link := gateSys.GetLink(gateAddress)
		if link == nil || link.State != "active" {
			writeJSON(w, 200, map[string]any{"ok": true, "linked": false})
			return
		}
		partner := link.GateB
		if gateAddress == link.GateB {
			partner = link.GateA
		}
		// Look up partner gate info for arrival data
		partnerGate, _ := gateSys.Get(partner)
		resp := map[string]any{
			"ok":              true,
			"linked":          true,
			"link_id":         link.LinkID,
			"remote_address":  partner,
			"direction":       link.Direction,
		}
		if partnerGate != nil {
			resp["remote_galaxy"] = partnerGate.Galaxy
			resp["remote_world"] = partnerGate.World
			resp["remote_position"] = partnerGate.Position
			resp["remote_arrival_offset"] = partnerGate.ArrivalOffset
			resp["remote_facing"] = partnerGate.Facing
		}
		writeJSON(w, 200, resp)

	case "DELETE":
		link := gateSys.Close(gateAddress)
		writeJSON(w, 200, map[string]any{
			"ok":          true,
			"link_closed": link != nil,
		})

	default:
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use GET or DELETE")
	}
}

// --- Item Transfer Handlers ---

// handleItem handles POST /nexus/item (send an item through a link)

// handleGlyphLookup handles POST /nexus/glyphs/lookup
// Finds a gate matching a glyph sequence.
func handleGlyphLookup(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use POST")
		return
	}
	var req struct {
		Glyphs []int `json:"glyphs"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, 400, "BAD_REQUEST", "Invalid JSON: "+err.Error())
		return
	}
	if len(req.Glyphs) == 0 {
		writeError(w, 400, "BAD_REQUEST", "Missing 'glyphs' array")
		return
	}

	// Convert 1-based Lua indices to 0-based Go indices
	goGlyphs := make([]int, len(req.Glyphs))
	for i, g := range req.Glyphs {
		goGlyphs[i] = g - 1
	}

	gate, _ := gateSys.FindByGlyphs(goGlyphs)
	if gate == nil {
		writeError(w, 404, "NO_MATCH", "No gate found for this glyph sequence")
		return
	}

	writeJSON(w, 200, map[string]interface{}{
		"ok":      true,
		"address": gate.Address,
		"galaxy":  gate.Galaxy,
		"world":   gate.World,
		"label":   gate.Label,
	})
}

func handleItem(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use POST")
		return
	}
	var req struct {
		EntryGate       string         `json:"entry_gate"`
		DestinationGate string         `json:"destination_gate"`
		Item            map[string]any `json:"item"`
		Velocity        Vec3           `json:"velocity"`
		Owner           string         `json:"owner"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, 400, "BAD_REQUEST", "Invalid JSON: "+err.Error())
		return
	}
	if req.DestinationGate == "" || req.Item == nil {
		writeError(w, 400, "BAD_REQUEST", "Missing 'destination_gate' or 'item'")
		return
	}
	qi := QueuedItem{
		Item:      req.Item,
		Velocity:  req.Velocity,
		Owner:     req.Owner,
		EntryGate: req.EntryGate,
	}
	gateSys.QueueItem(req.DestinationGate, qi)
	log.Printf("[nexus] item queued: %s → %s (owner %s)",
		req.EntryGate, req.DestinationGate, req.Owner)
	writeJSON(w, 200, map[string]any{"ok": true})
}

// handleItemAddress handles GET /nexus/item/<gate_address>
func handleItemAddress(w http.ResponseWriter, r *http.Request) {
	gateAddress := r.URL.Path[len("/nexus/item/"):]
	if gateAddress == "" {
		writeError(w, 400, "BAD_REQUEST", "Missing gate address in path")
		return
	}

	switch r.Method {
	case "GET":
		items := gateSys.FetchItems(gateAddress)
		writeJSON(w, 200, map[string]any{
			"ok":    true,
			"items": items,
			"count": len(items),
		})

	default:
		writeError(w, 405, "METHOD_NOT_ALLOWED", "Use GET")
	}
}

// --- Glyph Lookup ---

// GateGlyphMatch finds a gate whose glyph sequence matches the given indices.
// The glyph sequence is computed deterministically from the gate's route.
func (gs *GateSystem) FindByGlyphs(indices []int) (*Gate, []int) {
	gs.mu.RLock()
	defer gs.mu.RUnlock()
	for _, gate := range gs.gates {
		gateIndices := ComputeGateGlyphs(gate)
		if glyphMatch(gateIndices, indices) {
			return gate, gateIndices
		}
	}
	return nil, nil
}

// ComputeGateGlyphs converts a gate's address to a glyph sequence.
// This mirrors the Lua route_to_glyphs logic.
func ComputeGateGlyphs(gate *Gate) []int {
	// Parse the address: galaxy:world:gate_id
	parts := strings.SplitN(gate.Address, ":", 3)
	if len(parts) < 3 {
		return nil
	}
	galaxy := parts[0]
	world := parts[1]
	gateID := parts[2]

	// Determine glyph count (always 7 for storage — we match any prefix)
	// Generate all 7 and let the caller match partial sequences
	result := make([]int, 7)
	result[0] = hashStep(galaxy, 1001)
	result[1] = hashStep(galaxy, 2002)
	result[2] = hashStep(world, 3003)
	result[3] = hashStep(world, 4004)
	result[4] = hashStep(gateID, 5005)
	result[5] = hashStep(gateID, 6006)
	result[6] = hashStep(galaxy+world+gateID, 7007)
	return result
}

func hashStep(s string, salt int) int {
	h := salt
	for i := 0; i < len(s); i++ {
		h = (h*31 + int(s[i])) % 2147483647
	}
	return (h % 12) // 0-based for Go
}

// glyphMatch checks if the dialed indices match the gate's glyph sequence.
// Handles prefix matching: a 3-glyph dial matches the first 3 of a 7-glyph
// gate if the gate is same-world. We match exact sequences (3, 5, or 7).
func glyphMatch(gateGlyphs, dialed []int) bool {
	if len(dialed) > len(gateGlyphs) {
		return false
	}
	// For 3-glyph dial: match gateGlyphs[4..6] (same-world portion)
	// For 5-glyph dial: match gateGlyphs[2..6] (same-galaxy portion)
	// For 7-glyph dial: match all 7
	offset := len(gateGlyphs) - len(dialed)
	if offset < 0 {
		return false
	}
	for i := range dialed {
		if gateGlyphs[offset+i] != dialed[i] {
			return false
		}
	}
	return true
}
