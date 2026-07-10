package config

import (
	"os"
	"strconv"

	"github.com/BurntSushi/toml"
)

type Config struct {
	Server     ServerConfig     `toml:"server"`
	Database   DatabaseConfig   `toml:"database"`
	Limits     LimitsConfig     `toml:"limits"`
	JWT        JWTConfig        `toml:"jwt"`
	TURN       TURNConfig       `toml:"turn"`
	Federation FederationConfig `toml:"federation"`
}

type ServerConfig struct {
	Host string `toml:"host"`
	Port int    `toml:"port"`
	TLS  bool   `toml:"tls"`
	Cert string `toml:"cert"`
	Key  string `toml:"key"`
	// Mode controls registration: "private" requires an invite code, "public" allows open registration.
	Mode string `toml:"mode"`
}

type DatabaseConfig struct {
	Path string `toml:"path"`
	// Key encrypts the database at rest (SQLCipher). Set via SECURECHAT_DB_KEY
	// only — never store it in config.toml (that would defeat the purpose).
	Key string `toml:"-"`
}

type LimitsConfig struct {
	MaxMessageSize     int `toml:"max_message_size"`
	MaxRoomsPerUser    int `toml:"max_rooms_per_user"`
	OfflineTTLHours    int `toml:"offline_ttl_hours"`
	MaxOfflineMessages int `toml:"max_offline_messages"`
}

type JWTConfig struct {
	Secret  string `toml:"secret"`
	TTLDays int    `toml:"ttl_days"`
}

type TURNConfig struct {
	Enabled bool   `toml:"enabled"`
	URL     string `toml:"url"`
	Secret  string `toml:"secret"`
}

// FederationConfig controls server-to-server federation.
// mode must be "mesh_public" or "mesh_private" to activate federation.
type FederationConfig struct {
	// Secret that remote peers must send in X-Federation-Secret to call our S2S endpoints.
	Secret string `toml:"secret"`
	// AdminToken protects the /api/v1/admin/federation/* endpoints.
	AdminToken string `toml:"admin_token"`
	// PublicURL is this server's externally reachable URL (no trailing slash).
	// Required when adding this server as a peer from the outside.
	PublicURL string `toml:"public_url"`
	// Name is a human-readable label shown in the federation info endpoint.
	Name string `toml:"name"`
}

// IsMesh returns true when federation is active (mesh_public or mesh_private).
func (c *Config) IsMesh() bool {
	return c.Server.Mode == "mesh_public" || c.Server.Mode == "mesh_private"
}

// IsPublicReg returns true when open registration is allowed.
func (c *Config) IsPublicReg() bool {
	return c.Server.Mode == "public" || c.Server.Mode == "mesh_public"
}

func Load(path string) (*Config, error) {
	cfg := &Config{}
	cfg.Server.Host = "0.0.0.0"
	cfg.Server.Port = 8443
	cfg.Server.Mode = "private"
	cfg.Database.Path = "data.db"
	cfg.Limits.MaxMessageSize = 65536
	cfg.Limits.MaxRoomsPerUser = 50
	cfg.Limits.OfflineTTLHours = 72
	cfg.Limits.MaxOfflineMessages = 500
	cfg.JWT.TTLDays = 30
	cfg.JWT.Secret = "change_me_in_production"
	cfg.Federation.Name = "SecureChat Node"

	if _, err := os.Stat(path); err == nil {
		if _, err := toml.DecodeFile(path, cfg); err != nil {
			return nil, err
		}
	}

	// Environment overrides (handy for Docker: run with no config file).
	applyEnvOverrides(cfg)
	return cfg, nil
}

// applyEnvOverrides lets SECURECHAT_* environment variables override the
// deployment-relevant config fields, so the server can run from `docker run`
// with just an env var and no config.toml.
func applyEnvOverrides(cfg *Config) {
	if v := os.Getenv("SECURECHAT_JWT_SECRET"); v != "" {
		cfg.JWT.Secret = v
	}
	if v := os.Getenv("SECURECHAT_DB_PATH"); v != "" {
		cfg.Database.Path = v
	}
	if v := os.Getenv("SECURECHAT_DB_KEY"); v != "" {
		cfg.Database.Key = v
	}
	if v := os.Getenv("SECURECHAT_HOST"); v != "" {
		cfg.Server.Host = v
	}
	if v := os.Getenv("SECURECHAT_PORT"); v != "" {
		if p, err := strconv.Atoi(v); err == nil {
			cfg.Server.Port = p
		}
	}
	if v := os.Getenv("SECURECHAT_MODE"); v != "" {
		cfg.Server.Mode = v
	}
	if v := os.Getenv("SECURECHAT_TLS"); v != "" {
		cfg.Server.TLS = v == "1" || v == "true"
	}
	if v := os.Getenv("SECURECHAT_TLS_CERT"); v != "" {
		cfg.Server.Cert = v
	}
	if v := os.Getenv("SECURECHAT_TLS_KEY"); v != "" {
		cfg.Server.Key = v
	}
}
