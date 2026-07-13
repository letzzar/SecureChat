// Tester de la federación de 3 nodos de SecureChat.
//
// Registra a Bob en el Nodo 1 y a Alice en el Nodo 3 y valida, contra los
// servidores reales corriendo en Docker:
//
//	F1  descubrimiento cross-server de usuarios
//	F2  descubrimiento cross-server de salas públicas + relay de mensaje
//	F4  sala PRIVADA alojada en el Nodo 1 y usada por Alice desde el Nodo 3,
//	    comprobando además la PRIVACIDAD DE METADATOS: el emisor externo (`from`)
//	    llega vacío al otro extremo (el anfitrión solo ve payload opaco).
//
// No usa el cifrado E2E real (eso es del cliente); los payloads son opacos para
// el servidor, así que basta con blobs base64 para ejercitar el relay.
//
// Uso: go run . [urlNodo1 urlNodo3 homeURLNodo1]
//   por defecto: http://localhost:8451  http://localhost:8453  http://securechat-1:8443
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/crypto/blake2s"
)

var (
	s1   = "http://localhost:8451" // Nodo 1 (Bob)
	s3   = "http://localhost:8453" // Nodo 3 (Alice)
	home = "http://securechat-1:8443"

	pass  = 0
	fail  = 0
	fails []string
)

// isEmpty trata la clave ausente (nil) o "" como vacía: con from,omitempty el
// servidor omite el campo cuando lo vacía por privacidad.
func isEmpty(v any) bool { return v == nil || v == "" }

func check(cond bool, name string) {
	if cond {
		pass++
		fmt.Printf("  \033[32mPASS\033[0m %s\n", name)
	} else {
		fail++
		fails = append(fails, name)
		fmt.Printf("  \033[31mFAIL\033[0m %s\n", name)
	}
}

// ── HTTP helpers ──────────────────────────────────────────────────────────────

func randHex(n int) string { b := make([]byte, n); rand.Read(b); return hex.EncodeToString(b) }

type identity struct{ userID, pub, sign, token string }

func newIdentity() identity {
	pk := make([]byte, 32)
	rand.Read(pk)
	sum := blake2s.Sum256(pk)
	return identity{userID: hex.EncodeToString(sum[:]), pub: hex.EncodeToString(pk), sign: randHex(32)}
}

func post(base, path, token string, body any) (int, []byte) {
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", base+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, []byte(err.Error())
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func get(base, path, token string) (int, []byte) {
	req, _ := http.NewRequest("GET", base+path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, []byte(err.Error())
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func register(base, name string) identity {
	id := newIdentity()
	code, body := post(base, "/api/v1/register", "", map[string]string{
		"user_id": id.userID, "display_name": name, "public_key": id.pub, "sign_public": id.sign,
	})
	if code != 200 {
		fmt.Printf("register(%s) failed: %d %s\n", name, code, body)
		os.Exit(1)
	}
	var r struct{ Token string }
	json.Unmarshal(body, &r)
	id.token = r.Token
	return id
}

// ── WebSocket helper ─────────────────────────────────────────────────────────

type wsConn struct {
	c   *websocket.Conn
	in  chan map[string]any
}

func dialWS(base, token string) *wsConn {
	u := strings.Replace(base, "http", "ws", 1) + "/api/v1/ws?token=" + token
	c, _, err := websocket.DefaultDialer.Dial(u, nil)
	if err != nil {
		fmt.Printf("ws dial %s failed: %v\n", base, err)
		os.Exit(1)
	}
	w := &wsConn{c: c, in: make(chan map[string]any, 32)}
	go func() {
		for {
			_, data, err := c.ReadMessage()
			if err != nil {
				close(w.in)
				return
			}
			var m map[string]any
			if json.Unmarshal(data, &m) == nil {
				w.in <- m
			}
		}
	}()
	return w
}

func (w *wsConn) send(m map[string]any) { b, _ := json.Marshal(m); w.c.WriteMessage(websocket.TextMessage, b) }

// waitMsg waits for a message of the given type, up to d. Returns nil on timeout.
func (w *wsConn) waitMsg(typ string, d time.Duration) map[string]any {
	deadline := time.After(d)
	for {
		select {
		case m, ok := <-w.in:
			if !ok {
				return nil
			}
			if m["type"] == typ {
				return m
			}
		case <-deadline:
			return nil
		}
	}
}

func main() {
	if len(os.Args) >= 4 {
		s1, s3, home = os.Args[1], os.Args[2], os.Args[3]
	}
	fmt.Printf("Nodo1(Bob)=%s  Nodo3(Alice)=%s  home=%s\n\n", s1, s3, home)

	// Registro
	fmt.Println("== Registro ==")
	bob := register(s1, "Bob")
	alice := register(s3, "Alice")
	check(bob.token != "", "Bob registrado en Nodo 1")
	check(alice.token != "", "Alice registrada en Nodo 3")

	// ── F1: descubrimiento cross-server de usuarios ──────────────────────────
	fmt.Println("\n== F1: descubrimiento de usuarios cross-server ==")
	code, body := get(s1, "/api/v1/users?q=Alice", bob.token)
	foundAlice := code == 200 && strings.Contains(string(body), alice.userID)
	check(foundAlice, "Bob (Nodo 1) encuentra a Alice (Nodo 3) vía fan-out")

	// ── F2: sala pública cross-server ────────────────────────────────────────
	fmt.Println("\n== F2: sala pública cross-server ==")
	roomName := "sala-publica-" + randHex(3)
	code, body = post(s3, "/api/v1/rooms/public", alice.token, map[string]string{"room_name": roomName})
	var pub struct {
		RoomID string `json:"room_id"`
	}
	json.Unmarshal(body, &pub)
	check(code == 200 && pub.RoomID != "", "Alice crea sala pública en Nodo 3")

	code, body = get(s1, "/api/v1/rooms/public?q="+roomName, bob.token)
	// La sala vive en el Nodo 3, así que su server_url es el del Nodo 3.
	check(code == 200 && strings.Contains(string(body), pub.RoomID) && strings.Contains(string(body), "securechat-3"),
		"Bob (Nodo 1) descubre la sala pública remota (etiquetada con server_url)")

	// ── F4: sala privada remota + privacidad de metadatos ────────────────────
	fmt.Println("\n== F4: sala privada cross-server + privacidad de metadatos ==")
	roomID := randHex(32)
	salt := randHex(16)
	code, body = post(s1, "/api/v1/rooms", bob.token, map[string]string{
		"room_id": roomID, "room_name": "privada-" + randHex(2), "salt": salt,
	})
	check(code == 200, "Bob crea sala PRIVADA en Nodo 1 (su servidor = home)")

	bws := dialWS(s1, bob.token)
	aws := dialWS(s3, alice.token)

	// Bob se une localmente (sala local a su servidor).
	bws.send(map[string]any{"type": "room_join", "room_id": roomID})
	check(bws.waitMsg("room_joined", 3*time.Second) != nil, "Bob se une a la sala en Nodo 1")

	// Alice se une a la sala REMOTA a través de su servidor (Nodo 3), que la
	// enruta al home (Nodo 1) por S2S de forma anónima.
	aws.send(map[string]any{"type": "room_join", "room_id": roomID, "home": home, "private": true})
	check(aws.waitMsg("room_joined", 3*time.Second) != nil, "Alice se une a la sala remota vía Nodo 3")

	time.Sleep(1500 * time.Millisecond) // deja propagar la suscripción S2S

	// Bob -> Alice
	payloadBA := "QkEtcGF5bG9hZA==" // "BA-payload" en base64 (opaco para el servidor)
	bws.send(map[string]any{"type": "room_msg", "room_id": roomID, "nonce": "enc", "payload": payloadBA, "ts": time.Now().Unix()})
	m := aws.waitMsg("room_msg", 4*time.Second)
	check(m != nil && m["payload"] == payloadBA, "Alice (Nodo 3) recibe el mensaje de Bob (relay cross-server)")
	check(m != nil && isEmpty(m["from"]), "PRIVACIDAD: el `from` externo llega VACÍO a Alice (el host no revela quién habla)")

	// Alice -> Bob
	payloadAB := "QUItcGF5bG9hZA==" // "AB-payload"
	aws.send(map[string]any{"type": "room_msg", "room_id": roomID, "nonce": "enc", "payload": payloadAB, "ts": time.Now().Unix()})
	m = bws.waitMsg("room_msg", 4*time.Second)
	check(m != nil && m["payload"] == payloadAB, "Bob (Nodo 1) recibe el mensaje de Alice (relay de vuelta)")
	check(m != nil && isEmpty(m["from"]), "PRIVACIDAD: el `from` externo llega VACÍO a Bob")

	// ── Resumen ──────────────────────────────────────────────────────────────
	fmt.Printf("\n== Resultado: %d PASS, %d FAIL ==\n", pass, fail)
	if fail > 0 {
		for _, f := range fails {
			fmt.Println("  - FALLÓ:", f)
		}
		os.Exit(1)
	}
	fmt.Println("Federación de 3 nodos: OK (F1 + F2 + F4 con privacidad de metadatos).")
}
