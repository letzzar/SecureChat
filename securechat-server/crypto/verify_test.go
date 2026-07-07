package crypto

import (
	"crypto/ed25519"
	"encoding/hex"
	"strconv"
	"testing"
)

// buildSignedString mirrors the canonical string the server reconstructs in
// ws.handleDM, which in turn must match the app's messages_store.dart.
func buildSignedString(msgType, to, nonce, payload string, seq int64) string {
	s := msgType + ":" + to + ":" + nonce + ":" + payload
	if msgType == "dm" {
		s += ":" + strconv.FormatInt(seq, 10)
	}
	return s
}

func TestVerifySignature_DMRoundTrip(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)

	signed := buildSignedString("dm", "recipient_id", "nonceB64", "payloadB64", 1714900000123)
	sig := ed25519.Sign(priv, []byte(signed))

	if !VerifySignature(pub, []byte(signed), hex.EncodeToString(sig)) {
		t.Fatal("valid dm signature rejected")
	}

	// Tampered payload must fail.
	tampered := buildSignedString("dm", "recipient_id", "nonceB64", "EVIL", 1714900000123)
	if VerifySignature(pub, []byte(tampered), hex.EncodeToString(sig)) {
		t.Fatal("signature accepted over tampered content")
	}
}

func TestVerifySignature_NoiseRoundTrip(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	signed := buildSignedString("noise_init", "recipient_id", "nonceB64", "payloadB64", 0)
	sig := ed25519.Sign(priv, []byte(signed))
	if !VerifySignature(pub, []byte(signed), hex.EncodeToString(sig)) {
		t.Fatal("valid noise_init signature rejected")
	}
}

func TestVerifySignature_MalformedInputsFailClosed(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(nil)
	sig := ed25519.Sign(priv, []byte("msg"))

	if VerifySignature(pub[:16], []byte("msg"), hex.EncodeToString(sig)) {
		t.Fatal("accepted a truncated public key")
	}
	if VerifySignature(pub, []byte("msg"), "not-hex") {
		t.Fatal("accepted a non-hex signature")
	}
	if VerifySignature(pub, []byte("msg"), hex.EncodeToString(sig[:32])) {
		t.Fatal("accepted a truncated signature")
	}
}
