package config

import (
	"os"

	"github.com/BurntSushi/toml"
)

type Config struct {
	Server   ServerConfig   `toml:"server"`
	Database DatabaseConfig `toml:"database"`
	Limits   LimitsConfig   `toml:"limits"`
	JWT      JWTConfig      `toml:"jwt"`
	TURN     TURNConfig     `toml:"turn"`
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

	if _, err := os.Stat(path); os.IsNotExist(err) {
		return cfg, nil
	}

	if _, err := toml.DecodeFile(path, cfg); err != nil {
		return nil, err
	}
	return cfg, nil
}
