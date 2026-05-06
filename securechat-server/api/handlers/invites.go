package handlers

import (
	"database/sql"
	"net/http"
	"time"

	"github.com/securechat/server/db"
)

type createInviteResponse struct {
	Token     string `json:"token"`
	ExpiresAt int64  `json:"expires_at"`
}

func CreateInvite(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.Context().Value(ContextUserID).(string)

		const ttl = 48 * time.Hour
		token, err := db.CreateInvite(database, userID, ttl)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Could not create invite")
			return
		}

		writeJSON(w, http.StatusOK, createInviteResponse{
			Token:     token,
			ExpiresAt: time.Now().Add(ttl).Unix(),
		})
	}
}
