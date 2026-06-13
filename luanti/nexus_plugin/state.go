package main

import (
	"sync"
	"time"
)

// StateStore is the interface for storing/retrieving player state during transfers.
// Implementations: MemoryStateStore (prototype), SQLiteStateStore (production).
type StateStore interface {
	Store(player string, state *PlayerState) error
	Retrieve(player string) (*PlayerState, bool)
	Delete(player string) error
}

// storedState holds a player's state with metadata for TTL expiry.
type storedState struct {
	state     *PlayerState
	storedAt  time.Time
}

// MemoryStateStore is an in-memory state store. State is lost on proxy restart.
// Suitable for prototype/development. Use SQLiteStateStore for production.
type MemoryStateStore struct {
	mu    sync.RWMutex
	data  map[string]*storedState
	ttl   time.Duration
}

func NewMemoryStateStore(ttl time.Duration) *MemoryStateStore {
	store := &MemoryStateStore{
		data: make(map[string]*storedState),
		ttl:  ttl,
	}
	// Start background cleanup goroutine
	go store.cleanupLoop()
	return store
}

func (s *MemoryStateStore) Store(player string, state *PlayerState) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data[player] = &storedState{
		state:    state,
		storedAt: time.Now(),
	}
	return nil
}

func (s *MemoryStateStore) Retrieve(player string) (*PlayerState, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	entry, ok := s.data[player]
	if !ok {
		return nil, false
	}
	// Check TTL
	if time.Since(entry.storedAt) > s.ttl {
		return nil, false
	}
	return entry.state, true
}

func (s *MemoryStateStore) Delete(player string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.data, player)
	return nil
}

// cleanupLoop periodically removes expired states to prevent memory leaks
// from abandoned transfers (player disconnected, never arrived, etc.).
func (s *MemoryStateStore) cleanupLoop() {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		s.mu.Lock()
		now := time.Now()
		for player, entry := range s.data {
			if now.Sub(entry.storedAt) > s.ttl {
				delete(s.data, player)
			}
		}
		s.mu.Unlock()
	}
}
