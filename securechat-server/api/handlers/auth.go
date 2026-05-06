package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/securechat/server/config"
)

type contextKey string

const ContextUserID contextKey = "user_id"

type Claims struct {
	UserID string `json:"uid"`
	jwt.RegisteredClaims
}

func IssueJWT(cfg *config.Config, userID string) (string, error) {
	claims := Claims{
		UserID: userID,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Duration(cfg.JWT.TTLDays) * 24 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(cfg.JWT.Secret))
}

// ValidateJWT parses and validates a JWT string, returning the user_id claim.
func ValidateJWT(cfg *config.Config, tokenStr string) (string, error) {
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, jwt.ErrSignatureInvalid
		}
		return []byte(cfg.JWT.Secret), nil
	})
	if err != nil || !token.Valid {
		return "", jwt.ErrSignatureInvalid
	}
	return claims.UserID, nil
}

func AuthMiddleware(cfg *config.Config, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "missing_token", "Authorization header required")
			return
		}
		tokenStr := strings.TrimPrefix(header, "Bearer ")

		userID, err := ValidateJWT(cfg, tokenStr)
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
