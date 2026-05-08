package config

import (
	"os"

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

	if _, err := os.Stat(path); os.IsNotExist(err) {
		return cfg, nil
	}

	if _, err := toml.DecodeFile(path, cfg); err != nil {
		return nil, err
	}
	return cfg, nil
}
