package api

import (
	"database/sql"
	"net/http"

	"github.com/securechat/server/api/handlers"
	"github.com/securechat/server/config"
	"github.com/securechat/server/federation"
	"github.com/securechat/server/sfu"
	"github.com/securechat/server/ws"
)

func NewRouter(cfg *config.Config, database *sql.DB, hub *ws.Hub, sfuInst *sfu.SFU, fedClient *federation.Client) http.Handler {
	mux := http.NewServeMux()

	// ── Core API ──────────────────────────────────────────────────────────────
	mux.HandleFunc("GET /api/v1/health", handlers.Health)

	mux.HandleFunc("POST /api/v1/register", handlers.Register(cfg, database))

	mux.HandleFunc("POST /api/v1/invites",
		handlers.AuthMiddleware(cfg, handlers.CreateInvite(database)))

	mux.HandleFunc("GET /api/v1/users/{user_id}",
		handlers.AuthMiddleware(cfg, handlers.GetUser(database)))

	mux.HandleFunc("GET /api/v1/users",
		handlers.AuthMiddleware(cfg, handlers.SearchUsers(cfg, fedClient, database)))

	mux.HandleFunc("POST /api/v1/rooms",
		handlers.AuthMiddleware(cfg, handlers.CreateRoom(database)))

	mux.HandleFunc("GET /api/v1/rooms/{room_id}",
		handlers.AuthMiddleware(cfg, handlers.GetRoom(database)))

	mux.HandleFunc("GET /api/v1/rooms",
		handlers.AuthMiddleware(cfg, handlers.SearchRooms(database)))

	mux.HandleFunc("GET /api/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		ws.ServeWS(hub, database, cfg, sfuInst, fedClient, w, r)
	})

	// ── Federation public info (no auth) ──────────────────────────────────────
	mux.HandleFunc("GET /api/v1/federation", handlers.GetFederationInfo(cfg, database))

	// ── Federation admin (X-Admin-Token) ─────────────────────────────────────
	mux.HandleFunc("POST /api/v1/admin/federation/peers",
		handlers.AddFederationPeer(cfg, database))
	mux.HandleFunc("GET /api/v1/admin/federation/peers",
		handlers.ListFederationPeers(cfg, database))
	mux.HandleFunc("DELETE /api/v1/admin/federation/peers",
		handlers.RemoveFederationPeer(cfg, database))

	// ── Server-to-server endpoints (X-Federation-Secret) ─────────────────────
	mux.HandleFunc("GET /s2s/users/{user_id}",
		handlers.S2SGetUser(cfg, database))
	mux.HandleFunc("GET /s2s/users",
		handlers.S2SSearchUsers(cfg, database))
	mux.HandleFunc("POST /s2s/message",
		handlers.S2SRelayMessage(cfg, database, hub))

	return mux
}
