package handlers

import (
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"net/http"

	"github.com/securechat/server/config"
	"github.com/securechat/server/db"
	"github.com/securechat/server/federation"
	"golang.org/x/crypto/blake2s"
)

type registerRequest struct {
	UserID      string `json:"user_id"`
	DisplayName string `json:"display_name"`
	PublicKey   string `json:"public_key"`  // hex-encoded 32 bytes X25519
	SignPublic  string `json:"sign_public"` // hex-encoded 32 bytes Ed25519
	InviteCode  string `json:"invite_code"`
}

type registerResponse struct {
	Token string `json:"token"`
}

type userResponse struct {
	UserID      string `json:"user_id"`
	DisplayName string `json:"display_name"`
	PublicKey   string `json:"public_key"`
	SignPublic  string `json:"sign_public"`
	ServerURL   string `json:"server_url,omitempty"` // non-empty for federated users
}

func Register(cfg *config.Config, database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
			return
		}

		var req registerRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_json", "Invalid JSON body")
			return
		}

		if req.UserID == "" || req.DisplayName == "" || req.PublicKey == "" || req.SignPublic == "" {
			writeError(w, http.StatusBadRequest, "missing_fields", "user_id, display_name, public_key, sign_public required")
			return
		}

		pk, err := hex.DecodeString(req.PublicKey)
		if err != nil || len(pk) != 32 {
			writeError(w, http.StatusBadRequest, "invalid_public_key", "public_key must be 32-byte hex")
			return
		}
		sp, err := hex.DecodeString(req.SignPublic)
		if err != nil || len(sp) != 32 {
			writeError(w, http.StatusBadRequest, "invalid_sign_public", "sign_public must be 32-byte hex")
			return
		}

		// Identity binding (design §5): user_id must equal BLAKE2s(public_key).
		// Prevents registering an identifier that does not derive from the key.
		derived := blake2s.Sum256(pk)
		if hex.EncodeToString(derived[:]) != req.UserID {
			writeError(w, http.StatusBadRequest, "user_id_mismatch", "user_id must equal BLAKE2s(public_key)")
			return
		}

		existing, err := db.GetUser(database, req.UserID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}

		if existing != nil {
			// Idempotent: if keys match, renew JWT
			match, err := db.UserKeysMatch(database, req.UserID, pk, sp)
			if err != nil || !match {
				writeError(w, http.StatusConflict, "user_exists", "User ID already registered with different keys")
				return
			}
		} else {
			// New user: in private/mesh_private mode require and consume a valid invite token.
			if !cfg.IsPublicReg() {
				if req.InviteCode == "" {
					writeError(w, http.StatusForbidden, "invite_required", "An invite code is required to register")
					return
				}
				ok, err := db.UseInvite(database, req.InviteCode)
				if err != nil {
					writeError(w, http.StatusInternalServerError, "db_error", "Database error")
					return
				}
				if !ok {
					writeError(w, http.StatusForbidden, "invalid_invite", "Invalid or expired invite code")
					return
				}
			}

			u := &db.User{
				UserID:      req.UserID,
				DisplayName: req.DisplayName,
				PublicKey:   pk,
				SignPublic:  sp,
			}
			if err := db.CreateUser(database, u); err != nil {
				writeError(w, http.StatusInternalServerError, "db_error", "Could not create user")
				return
			}
		}

		token, err := IssueJWT(cfg, req.UserID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "jwt_error", "Could not issue token")
			return
		}

		writeJSON(w, http.StatusOK, registerResponse{Token: token})
	}
}

func GetUser(database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := r.PathValue("user_id")
		if userID == "" {
			writeError(w, http.StatusBadRequest, "missing_user_id", "user_id required")
			return
		}

		u, err := db.GetUser(database, userID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}
		if u == nil {
			writeError(w, http.StatusNotFound, "not_found", "User not found")
			return
		}

		writeJSON(w, http.StatusOK, userResponse{
			UserID:      u.UserID,
			DisplayName: u.DisplayName,
			PublicKey:   hex.EncodeToString(u.PublicKey),
			SignPublic:  hex.EncodeToString(u.SignPublic),
		})
	}
}

func SearchUsers(cfg *config.Config, fedClient *federation.Client, database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query().Get("q")
		if q == "" {
			writeError(w, http.StatusBadRequest, "missing_q", "Query parameter q required")
			return
		}

		users, err := db.SearchUsers(database, q, 20)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "db_error", "Database error")
			return
		}

		results := make([]userResponse, 0, len(users))
		for _, u := range users {
			results = append(results, userResponse{
				UserID:      u.UserID,
				DisplayName: u.DisplayName,
				PublicKey:   hex.EncodeToString(u.PublicKey),
				SignPublic:  hex.EncodeToString(u.SignPublic),
			})
		}

		// In mesh mode, fan-out to federated peers and aggregate results.
		if cfg.IsMesh() && fedClient != nil {
			peers, _ := db.GetFederationPeers(database)
			if len(peers) > 0 {
				for _, u := range fedClient.SearchUsers(peers, q) {
					results = append(results, userResponse{
						UserID:      u.UserID,
						DisplayName: u.DisplayName,
						PublicKey:   u.PublicKey,
						SignPublic:  u.SignPublic,
						ServerURL:   u.ServerURL,
					})
				}
			}
		}

		writeJSON(w, http.StatusOK, results)
	}
}
