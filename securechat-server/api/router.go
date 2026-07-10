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

	// ── Public rooms + moderation ─────────────────────────────────────────────
	mux.HandleFunc("POST /api/v1/rooms/public",
		handlers.AuthMiddleware(cfg, handlers.CreatePublicRoom(database)))
	mux.HandleFunc("GET /api/v1/rooms/public",
		handlers.AuthMiddleware(cfg, handlers.SearchPublicRooms(cfg, fedClient, database)))
	mux.HandleFunc("POST /api/v1/rooms/{room_id}/join",
		handlers.AuthMiddleware(cfg, handlers.JoinPublicRoom(database)))
	mux.HandleFunc("GET /api/v1/rooms/{room_id}/members",
		handlers.AuthMiddleware(cfg, handlers.RoomMembers(database, hub, fedClient)))
	mux.HandleFunc("POST /api/v1/rooms/{room_id}/kick",
		handlers.AuthMiddleware(cfg, handlers.KickMember(database, hub, fedClient)))
	mux.HandleFunc("POST /api/v1/rooms/{room_id}/ban",
		handlers.AuthMiddleware(cfg, handlers.BanMember(database, hub, fedClient)))
	mux.HandleFunc("POST /api/v1/rooms/{room_id}/unban",
		handlers.AuthMiddleware(cfg, handlers.UnbanMember(database, hub, fedClient)))
	mux.HandleFunc("POST /api/v1/rooms/{room_id}/admin",
		handlers.AuthMiddleware(cfg, handlers.SetRoomAdmin(database, hub, fedClient)))

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
	mux.HandleFunc("GET /s2s/rooms/public",
		handlers.S2SSearchPublicRooms(cfg, database))
	mux.HandleFunc("POST /s2s/room/subscribe",
		handlers.S2SRoomSubscribe(cfg, database, hub))
	mux.HandleFunc("POST /s2s/room/unsubscribe",
		handlers.S2SRoomUnsubscribe(cfg, database, hub))
	mux.HandleFunc("POST /s2s/room/message",
		handlers.S2SRoomMessage(cfg, database, hub, fedClient))
	mux.HandleFunc("GET /s2s/room/{room_id}/members",
		handlers.S2SRoomMembers(cfg, database))
	mux.HandleFunc("POST /s2s/room/moderate",
		handlers.S2SRoomModerate(cfg, database, hub, fedClient))
	mux.HandleFunc("POST /s2s/room/kicked",
		handlers.S2SRoomKicked(cfg, hub))

	return mux
}
