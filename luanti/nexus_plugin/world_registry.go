package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// =============================================================================
// Universe Configuration
// =============================================================================

type UniverseConfig struct {
	Galaxies map[string]GalaxyConfig `json:"galaxies"`
}

type GalaxyConfig struct {
	Label           string             `json:"label"`
	Tier            int                `json:"tier"`
	MaxRandomWorlds int                `json:"max_random_worlds"`
	RandomParams    RandomWorldParams  `json:"random_world_params"`
	StaticWorlds    []string           `json:"static_worlds"`
}

type RandomWorldParams struct {
	Ores           []string `json:"ores"`
	Hazards        []string `json:"hazards"`
	RuinTier       int      `json:"ruin_tier"`
	TimeSpeedRange [2]int   `json:"time_speed_range"`
}

func LoadUniverseConfig(path string) (*UniverseConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read universe config: %w", err)
	}
	var cfg UniverseConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse universe config: %w", err)
	}
	if cfg.Galaxies == nil {
		cfg.Galaxies = make(map[string]GalaxyConfig)
	}
	return &cfg, nil
}

// =============================================================================
// World Registry (SQLite)
// =============================================================================

// WorldRecord represents a world in the registry database.
type WorldRecord struct {
	WorldName   string
	Galaxy      string
	Tier        int
	WorldType   string // "static" or "dynamic"
	Seed        int64
	WorldDir    string
	State       string // "offline", "starting", "online", "stopping"
	Port        int
	Pid         int
	ConfigPath  string
	Ores        string
	Hazards     string
	TimeSpeed   int
	RuinSpacing int
	Description string
	CreatedAt   int64
	LastVisited int64
	VisitCount  int
}

// GateRecord represents a gate in the registry database.
// This replaces the in-memory gate map with persistent storage.
type GateRecord struct {
	Address      string
	Label        string
	Galaxy       string
	World        string
	PosX         float64
	PosY         float64
	PosZ         float64
	ArrivalX     float64
	ArrivalY     float64
	ArrivalZ     float64
	Facing       int
	Powered      bool
	Obstructed   bool
	Ancient      bool
	RegisteredAt int64
}

// WorldRegistry is the SQLite-backed world and gate registry.
// It persists across proxy restarts, enabling dialing offline worlds.
type WorldRegistry struct {
	db *sql.DB
}

func NewWorldRegistry(dbPath string) (*WorldRegistry, error) {
	db, err := sql.Open("sqlite3", dbPath+"?_busy_timeout=5000&_journal_mode=WAL")
	if err != nil {
		return nil, fmt.Errorf("open world registry: %w", err)
	}

	// Create tables
	schema := `
	CREATE TABLE IF NOT EXISTS worlds (
		world_name   TEXT PRIMARY KEY,
		galaxy       TEXT NOT NULL,
		tier         INTEGER DEFAULT 0,
		world_type   TEXT NOT NULL DEFAULT 'static',
		seed         INTEGER NOT NULL DEFAULT 0,
		world_dir    TEXT NOT NULL,
		state        TEXT NOT NULL DEFAULT 'offline',
		port         INTEGER DEFAULT 0,
		pid          INTEGER DEFAULT 0,
		config_path  TEXT DEFAULT '',
		ores         TEXT DEFAULT '',
		hazards      TEXT DEFAULT '',
		time_speed   INTEGER DEFAULT 72,
		ruin_spacing INTEGER DEFAULT 32,
		description  TEXT DEFAULT '',
		created_at   INTEGER NOT NULL,
		last_visited INTEGER DEFAULT 0,
		visit_count  INTEGER DEFAULT 0
	);

	CREATE TABLE IF NOT EXISTS gates (
		address      TEXT PRIMARY KEY,
		label        TEXT DEFAULT '',
		galaxy       TEXT NOT NULL,
		world        TEXT NOT NULL,
		pos_x        REAL NOT NULL,
		pos_y        REAL NOT NULL,
		pos_z        REAL NOT NULL,
		arrival_x    REAL DEFAULT 0,
		arrival_y    REAL DEFAULT 1,
		arrival_z    REAL DEFAULT -2,
		facing       INTEGER DEFAULT 0,
		powered      INTEGER DEFAULT 1,
		obstructed   INTEGER DEFAULT 0,
		ancient      INTEGER DEFAULT 0,
		registered_at INTEGER NOT NULL
	);

	CREATE INDEX IF NOT EXISTS idx_gates_world ON gates(world);
	CREATE INDEX IF NOT EXISTS idx_worlds_galaxy ON worlds(galaxy);
	CREATE INDEX IF NOT EXISTS idx_worlds_state ON worlds(state);
	`

	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("create schema: %w", err)
	}

	return &WorldRegistry{db: db}, nil
}

func (wr *WorldRegistry) Close() error {
	return wr.db.Close()
}

// --- World CRUD ---

func (wr *WorldRegistry) UpsertWorld(w *WorldRecord) error {
	_, err := wr.db.Exec(`
		INSERT OR REPLACE INTO worlds
		(world_name, galaxy, tier, world_type, seed, world_dir, state, port, pid,
		 config_path, ores, hazards, time_speed, ruin_spacing, description,
		 created_at, last_visited, visit_count)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		w.WorldName, w.Galaxy, w.Tier, w.WorldType, w.Seed, w.WorldDir,
		w.State, w.Port, w.Pid, w.ConfigPath, w.Ores, w.Hazards,
		w.TimeSpeed, w.RuinSpacing, w.Description,
		w.CreatedAt, w.LastVisited, w.VisitCount)
	return err
}

func (wr *WorldRegistry) GetWorld(name string) (*WorldRecord, error) {
	var w WorldRecord
	err := wr.db.QueryRow(`SELECT * FROM worlds WHERE world_name = ?`, name).Scan(
		&w.WorldName, &w.Galaxy, &w.Tier, &w.WorldType, &w.Seed, &w.WorldDir,
		&w.State, &w.Port, &w.Pid, &w.ConfigPath, &w.Ores, &w.Hazards,
		&w.TimeSpeed, &w.RuinSpacing, &w.Description,
		&w.CreatedAt, &w.LastVisited, &w.VisitCount)
	if err != nil {
		return nil, err
	}
	return &w, nil
}

func (wr *WorldRegistry) UpdateWorldState(name, state string, port, pid int) error {
	_, err := wr.db.Exec(
		`UPDATE worlds SET state = ?, port = ?, pid = ? WHERE world_name = ?`,
		state, port, pid, name)
	return err
}

func (wr *WorldRegistry) UpdateWorldVisited(name string) error {
	_, err := wr.db.Exec(
		`UPDATE worlds SET last_visited = ?, visit_count = visit_count + 1 WHERE world_name = ?`,
		time.Now().Unix(), name)
	return err
}

func (wr *WorldRegistry) ListWorlds() ([]WorldRecord, error) {
	rows, err := wr.db.Query(`SELECT * FROM worlds ORDER BY world_name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var worlds []WorldRecord
	for rows.Next() {
		var w WorldRecord
		if err := rows.Scan(
			&w.WorldName, &w.Galaxy, &w.Tier, &w.WorldType, &w.Seed, &w.WorldDir,
			&w.State, &w.Port, &w.Pid, &w.ConfigPath, &w.Ores, &w.Hazards,
			&w.TimeSpeed, &w.RuinSpacing, &w.Description,
			&w.CreatedAt, &w.LastVisited, &w.VisitCount); err != nil {
			return nil, err
		}
		worlds = append(worlds, w)
	}
	return worlds, nil
}

func (wr *WorldRegistry) ListWorldsByState(state string) ([]WorldRecord, error) {
	rows, err := wr.db.Query(`SELECT * FROM worlds WHERE state = ?`, state)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var worlds []WorldRecord
	for rows.Next() {
		var w WorldRecord
		if err := rows.Scan(
			&w.WorldName, &w.Galaxy, &w.Tier, &w.WorldType, &w.Seed, &w.WorldDir,
			&w.State, &w.Port, &w.Pid, &w.ConfigPath, &w.Ores, &w.Hazards,
			&w.TimeSpeed, &w.RuinSpacing, &w.Description,
			&w.CreatedAt, &w.LastVisited, &w.VisitCount); err != nil {
			return nil, err
		}
		worlds = append(worlds, w)
	}
	return worlds, nil
}

// --- Gate CRUD (persists across server restarts) ---

func (wr *WorldRegistry) UpsertGate(g *GateRecord) error {
	_, err := wr.db.Exec(`
		INSERT OR REPLACE INTO gates
		(address, label, galaxy, world, pos_x, pos_y, pos_z,
		 arrival_x, arrival_y, arrival_z, facing, powered, obstructed, ancient,
		 registered_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		g.Address, g.Label, g.Galaxy, g.World, g.PosX, g.PosY, g.PosZ,
		g.ArrivalX, g.ArrivalY, g.ArrivalZ, g.Facing, g.Powered, g.Obstructed,
		g.Ancient, g.RegisteredAt)
	return err
}

func (wr *WorldRegistry) GetGate(address string) (*GateRecord, error) {
	var g GateRecord
	var powered, obstructed, ancient int
	err := wr.db.QueryRow(`SELECT * FROM gates WHERE address = ?`, address).Scan(
		&g.Address, &g.Label, &g.Galaxy, &g.World, &g.PosX, &g.PosY, &g.PosZ,
		&g.ArrivalX, &g.ArrivalY, &g.ArrivalZ, &g.Facing, &powered, &obstructed,
		&ancient, &g.RegisteredAt)
	if err != nil {
		return nil, err
	}
	g.Powered = powered != 0
	g.Obstructed = obstructed != 0
	g.Ancient = ancient != 0
	return &g, nil
}

func (wr *WorldRegistry) DeleteGate(address string) error {
	_, err := wr.db.Exec(`DELETE FROM gates WHERE address = ?`, address)
	return err
}

func (wr *WorldRegistry) ListGatesByWorld(world string) ([]GateRecord, error) {
	rows, err := wr.db.Query(`SELECT * FROM gates WHERE world = ?`, world)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var gates []GateRecord
	for rows.Next() {
		var g GateRecord
		var powered, obstructed, ancient int
		if err := rows.Scan(
			&g.Address, &g.Label, &g.Galaxy, &g.World, &g.PosX, &g.PosY, &g.PosZ,
			&g.ArrivalX, &g.ArrivalY, &g.ArrivalZ, &g.Facing, &powered, &obstructed,
			&ancient, &g.RegisteredAt); err != nil {
			return nil, err
		}
		g.Powered = powered != 0
		g.Obstructed = obstructed != 0
		g.Ancient = ancient != 0
		gates = append(gates, g)
	}
	return gates, nil
}

// ResetAllWorldStates sets all worlds to offline. Called on proxy startup
// to recover from a crash (all server processes died with the proxy).
func (wr *WorldRegistry) ResetAllWorldStates() error {
	_, err := wr.db.Exec(`UPDATE worlds SET state = 'offline', port = 0, pid = 0`)
	return err
}
