package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/securechat/server/api"
	"github.com/securechat/server/config"
	"github.com/securechat/server/db"
	"github.com/securechat/server/sfu"
	"github.com/securechat/server/ws"
)

func main() {
	configPath := flag.String("config", "config.toml", "Path to config file")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	database, err := db.Open(cfg.Database.Path)
	if err != nil {
		log.Fatalf("open database: %v", err)
	}
	defer database.Close()

	// Bootstrap: if no users exist yet, generate the first invite token
	count, err := db.CountUsers(database)
	if err != nil {
		log.Fatalf("count users: %v", err)
	}
	if count == 0 {
		token, err := db.CreateInvite(database, "bootstrap", 30*24*time.Hour)
		if err != nil {
			log.Fatalf("create bootstrap invite: %v", err)
		}
		log.Printf("╔══════════════════════════════════════════════════════╗")
		log.Printf("║          BOOTSTRAP INVITE CODE (first user)          ║")
		log.Printf("║                                                      ║")
		log.Printf("║  %s  ║", token)
		log.Printf("║                                                      ║")
		log.Printf("║  Valid for 30 days. Share securely.                  ║")
		log.Printf("╚══════════════════════════════════════════════════════╝")
	}

	hub := ws.NewHub()

	sfuInst := sfu.New(nil) // nil = use default Google STUN
	sfuInst.SetOnPeerLeft(func(roomID, userID string) {
		hub.BroadcastRoom(roomID, nil, &ws.OutgoingMessage{
			Type:   "voice_user_left",
			From:   userID,
			RoomID: roomID,
		})
	})

	// Background: purge expired offline messages and rooms every hour
	go func() {
		for {
			time.Sleep(time.Hour)
			if err := db.DeleteExpiredMessages(database); err != nil {
				log.Printf("purge expired messages: %v", err)
			}
			if err := db.DeleteExpiredRooms(database); err != nil {
				log.Printf("purge expired rooms: %v", err)
			}
		}
	}()

	router := api.NewRouter(cfg, database, hub, sfuInst)

	addr := fmt.Sprintf("%s:%d", cfg.Server.Host, cfg.Server.Port)
	log.Printf("SecureChat server starting on %s (TLS=%v, mode=%s)", addr, cfg.Server.TLS, cfg.Server.Mode)

	if cfg.Server.TLS {
		if cfg.Server.Cert == "" || cfg.Server.Key == "" {
			log.Fatal("TLS enabled but cert/key not configured")
		}
		log.Fatal(http.ListenAndServeTLS(addr, cfg.Server.Cert, cfg.Server.Key, router))
	} else {
		log.Fatal(http.ListenAndServe(addr, router))
	}
}
