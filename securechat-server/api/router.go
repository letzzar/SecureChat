package api

import (
	"database/sql"
	"net/http"

	"github.com/securechat/server/api/handlers"
	"github.com/securechat/server/config"
	"github.com/securechat/server/sfu"
	"github.com/securechat/server/ws"
)

func NewRouter(cfg *config.Config, database *sql.DB, hub *ws.Hub, sfuInst *sfu.SFU) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/v1/health", handlers.Health)

	mux.HandleFunc("POST /api/v1/register", handlers.Register(cfg, database))

	mux.HandleFunc("POST /api/v1/invites",
		handlers.AuthMiddleware(cfg, handlers.CreateInvite(database)))

	mux.HandleFunc("GET /api/v1/users/{user_id}",
		handlers.AuthMiddleware(cfg, handlers.GetUser(database)))

	mux.HandleFunc("GET /api/v1/users",
		handlers.AuthMiddleware(cfg, handlers.SearchUsers(database)))

	mux.HandleFunc("POST /api/v1/rooms",
		handlers.AuthMiddleware(cfg, handlers.CreateRoom(database)))

	mux.HandleFunc("GET /api/v1/rooms/{room_id}",
		handlers.AuthMiddleware(cfg, handlers.GetRoom(database)))

	mux.HandleFunc("GET /api/v1/rooms",
		handlers.AuthMiddleware(cfg, handlers.SearchRooms(database)))

	mux.HandleFunc("GET /api/v1/ws", func(w http.ResponseWriter, r *http.Request) {
		ws.ServeWS(hub, database, cfg, sfuInst, w, r)
	})

	return mux
}
