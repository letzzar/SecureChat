// Package crypto provides server-side verification of Ed25519 signatures on
// incoming client messages. The server never decrypts payloads; it only
// confirms that the connected client actually signed the message with the
// private key matching the sign_public it registered (anti-spam,
// anti-impersonation — see SECURECHAT_DESIGN.md §7, §13).
package crypto

import (
	"crypto/ed25519"
	"encoding/hex"
)

// VerifySignature reports whether sigHex is a valid Ed25519 signature over
// message, produced by the private key matching publicKey. All malformed
// inputs (wrong key/signature length, non-hex signature) fail closed.
func VerifySignature(publicKey []byte, message []byte, sigHex string) bool {
	if len(publicKey) != ed25519.PublicKeySize {
		return false
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(publicKey), message, sig)
}
