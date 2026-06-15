package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	proxy "github.com/HimbeerserverDE/mt-multiserver-proxy"
	_ "github.com/mattn/go-sqlite3"
)

// SQLiteStateStore persists player transfer state to SQLite.
// State survives proxy restarts — critical for players mid-transfer.
type SQLiteStateStore struct {
	db  *sql.DB
	ttl time.Duration
}

func NewSQLiteStateStore(ttl time.Duration) (*SQLiteStateStore, error) {
	dbPath := proxy.Path("nexus_state.sqlite")
	db, err := sql.Open("sqlite3", dbPath+"?_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("open nexus_state.sqlite: %w", err)
	}

	// Create table
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS player_state (
			player    TEXT PRIMARY KEY,
			data      TEXT NOT NULL,
			stored_at INTEGER NOT NULL
		)
	`)
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("create table: %w", err)
	}

	store := &SQLiteStateStore{db: db, ttl: ttl}

	// Start background cleanup
	go store.cleanupLoop()

	return store, nil
}

func (s *SQLiteStateStore) Store(player string, state *PlayerState) error {
	data, err := json.Marshal(state)
	if err != nil {
		return fmt.Errorf("marshal state: %w", err)
	}
	_, err = s.db.Exec(
		`INSERT OR REPLACE INTO player_state (player, data, stored_at) VALUES (?, ?, ?)`,
		player, string(data), time.Now().Unix(),
	)
	return err
}

func (s *SQLiteStateStore) Retrieve(player string) (*PlayerState, bool) {
	var data string
	var storedAt int64
	err := s.db.QueryRow(
		`SELECT data, stored_at FROM player_state WHERE player = ?`, player,
	).Scan(&data, &storedAt)
	if err != nil {
		return nil, false
	}
	// Check TTL
	if time.Since(time.Unix(storedAt, 0)) > s.ttl {
		// Expired — clean it up
		s.Delete(player)
		return nil, false
	}
	var state PlayerState
	if err := json.Unmarshal([]byte(data), &state); err != nil {
		return nil, false
	}
	return &state, true
}

func (s *SQLiteStateStore) Delete(player string) error {
	_, err := s.db.Exec(`DELETE FROM player_state WHERE player = ?`, player)
	return err
}

// cleanupLoop removes expired states every 60 seconds
func (s *SQLiteStateStore) cleanupLoop() {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	cutoff := time.Now().Add(-s.ttl).Unix()
	for range ticker.C {
		newCutoff := time.Now().Add(-s.ttl).Unix()
		if newCutoff != cutoff {
			cutoff = newCutoff
			s.db.Exec(`DELETE FROM player_state WHERE stored_at < ?`, cutoff)
		}
	}
}
