package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	jwtauth "github.com/securechat/server/auth"
	"github.com/securechat/server/config"
)

type contextKey string

const ContextUserID contextKey = "user_id"

// IssueJWT delegates to the auth package.
func IssueJWT(cfg *config.Config, userID string) (string, error) {
	return jwtauth.IssueJWT(cfg, userID)
}

// ValidateJWT delegates to the auth package.
func ValidateJWT(cfg *config.Config, tokenStr string) (string, error) {
	return jwtauth.ValidateJWT(cfg, tokenStr)
}

func AuthMiddleware(cfg *config.Config, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "missing_token", "Authorization header required")
			return
		}
		tokenStr := strings.TrimPrefix(header, "Bearer ")

		userID, err := jwtauth.ValidateJWT(cfg, tokenStr)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "invalid_token", "Token invalid or expired")
			return
		}

		ctx := context.WithValue(r.Context(), ContextUserID, userID)
		next(w, r.WithContext(ctx))
	}
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"code": code, "msg": msg})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
