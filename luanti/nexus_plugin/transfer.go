package main

import (
	"fmt"
	"log"
	"sync"
	"time"
)

// TransferState represents the state of a player's transfer lifecycle.
type TransferState int

const (
	StateIdle       TransferState = iota // No active transfer
	StateDeparting                        // Depart initiated, hop in progress
	StateInTransit                        // Hop confirmed, waiting for arrival
	StateArriving                         // Player arrived, state being restored
	StateFailed                           // Transfer failed, cleanup needed
)

func (s TransferState) String() string {
	switch s {
	case StateIdle:
		return "IDLE"
	case StateDeparting:
		return "DEPARTING"
	case StateInTransit:
		return "IN_TRANSIT"
	case StateArriving:
		return "ARRIVING"
	case StateFailed:
		return "FAILED"
	default:
		return "UNKNOWN"
	}
}

// playerTransfer tracks one player's transfer state and ensures
// only one transfer per player at a time.
type playerTransfer struct {
	mu          sync.Mutex
	state       TransferState
	destination string
	timer       *time.Timer
}

// TransferManager manages transfer state for all players.
type TransferManager struct {
	mu        sync.RWMutex
	transfers map[string]*playerTransfer
	store     StateStore
	config    Config
}

func NewTransferManager(store StateStore, cfg Config) *TransferManager {
	return &TransferManager{
		transfers: make(map[string]*playerTransfer),
		store:     store,
		config:    cfg,
	}
}

// BeginTransfer starts a new transfer for a player.
// Returns an error if the player is already in a transfer.
func (tm *TransferManager) BeginTransfer(player string) (*playerTransfer, error) {
	tm.mu.Lock()
	defer tm.mu.Unlock()

	pt, exists := tm.transfers[player]
	if !exists {
		pt = &playerTransfer{}
		tm.transfers[player] = pt
	}

	pt.mu.Lock()
	defer pt.mu.Unlock()

	if pt.state != StateIdle && pt.state != StateFailed {
		return nil, fmt.Errorf("player is already transferring (state: %s)", pt.state)
	}

	pt.state = StateDeparting
	pt.destination = ""
	if pt.timer != nil {
		pt.timer.Stop()
		pt.timer = nil
	}
	return pt, nil
}

// ConfirmHop is called after cc.Hop() succeeds. Transitions to IN_TRANSIT
// and starts the arrival timeout.
func (tm *TransferManager) ConfirmHop(player, destination string) {
	pt := tm.getOrCreate(player)
	pt.mu.Lock()
	defer pt.mu.Unlock()

	pt.state = StateInTransit
	pt.destination = destination
	log.Printf("[nexus] transfer %s → %s: IN_TRANSIT (waiting for arrival)", player, destination)

	// Start arrival timeout — if the player never arrives/requests state,
	// we clean up to prevent orphaned state
	pt.timer = time.AfterFunc(tm.config.ArrivalTimeout, func() {
		pt.mu.Lock()
		if pt.state == StateInTransit {
			log.Printf("[nexus] WARNING: arrival timeout for %s — cleaning up", player)
			pt.state = StateFailed
			tm.store.Delete(player)
		}
		pt.mu.Unlock()
	})
}

// CompleteTransfer is called after the destination server confirms
// state restoration (DELETE /state/:player). Returns to IDLE.
func (tm *TransferManager) CompleteTransfer(player string) {
	pt := tm.getOrCreate(player)
	pt.mu.Lock()
	defer pt.mu.Unlock()

	pt.state = StateIdle
	pt.destination = ""
	if pt.timer != nil {
		pt.timer.Stop()
		pt.timer = nil
	}
	log.Printf("[nexus] transfer complete: %s → IDLE", player)
}

// FailTransfer marks a transfer as failed and cleans up state.
func (tm *TransferManager) FailTransfer(player string) {
	pt := tm.getOrCreate(player)
	pt.mu.Lock()
	defer pt.mu.Unlock()

	pt.state = StateFailed
	pt.destination = ""
	if pt.timer != nil {
		pt.timer.Stop()
		pt.timer = nil
	}
	log.Printf("[nexus] transfer failed: %s", player)
}

// HandleDisconnect is called when a player disconnects from the proxy.
// If they were in transit, we clean up after a short delay (they might
// be reconnecting due to the hop).
func (tm *TransferManager) HandleDisconnect(player string) {
	pt := tm.getOrCreate(player)
	pt.mu.Lock()
	defer pt.mu.Unlock()

	if pt.state == StateInTransit || pt.state == StateDeparting {
		log.Printf("[nexus] %s disconnected during %s — scheduling cleanup", player, pt.state)
		// Give a grace period — the hop itself involves a brief disconnect
		pt.timer = time.AfterFunc(10*time.Second, func() {
			pt2 := tm.getOrCreate(player)
			pt2.mu.Lock()
			if pt2.state == StateInTransit || pt2.state == StateDeparting {
				log.Printf("[nexus] %s did not return — cleaning up transfer", player)
				pt2.state = StateFailed
				tm.store.Delete(player)
			}
			pt2.mu.Unlock()
		})
	}
}

// ActiveCount returns the number of players currently in a transfer.
func (tm *TransferManager) ActiveCount() int {
	tm.mu.RLock()
	defer tm.mu.RUnlock()
	count := 0
	for _, pt := range tm.transfers {
		pt.mu.Lock()
		if pt.state != StateIdle && pt.state != StateFailed {
			count++
		}
		pt.mu.Unlock()
	}
	return count
}

func (tm *TransferManager) getOrCreate(player string) *playerTransfer {
	tm.mu.Lock()
	defer tm.mu.Unlock()
	pt, ok := tm.transfers[player]
	if !ok {
		pt = &playerTransfer{}
		tm.transfers[player] = pt
	}
	return pt
}
