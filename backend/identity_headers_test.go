package backend

import (
	"net/http"
	"testing"
)

func TestDeviceHeaderOptOutPersistsAndTransfers(t *testing.T) {
	a := newTestApp(t)
	token := create(t, a)
	identity := a.state.Groups[0].Identity
	identity.OmitDeviceHeaders = true
	expect(t, call(a, "PUT", "/api/identity", token, input{Identity: identity}), 200)
	expect(t, call(a, "PUT", "/api/subscription", token, input{URL: "https://example.com/sub"}), 200)
	requested := false
	a.client = &http.Client{Transport: transportFunc(func(r *http.Request) (*http.Response, error) {
		requested = true
		for _, key := range []string{"x-hwid", "x-device-os", "x-device-model", "x-device-locale"} {
			if _, exists := r.Header[http.CanonicalHeaderKey(key)]; exists {
				t.Errorf("disabled header sent: %s", key)
			}
		}
		if r.UserAgent() != identity.UserAgent {
			t.Error("User-Agent not preserved")
		}
		return fakeResponse(200, "vless://test@example.com:443"), nil
	})}
	expect(t, call(a, "POST", "/api/subscription/refresh", token, nil), 200)
	if !requested {
		t.Fatal("subscription was not requested")
	}
	reopened, err := openApp(a.path)
	if err != nil {
		t.Fatal(err)
	}
	if !reopened.state.Groups[0].Identity.OmitDeviceHeaders {
		t.Fatal("opt-out not persisted")
	}
	code := expect(t, call(a, "POST", "/api/transfer/export", token, nil), 200)["code"].(string)
	imported, err := decodeTransfer(code)
	if err != nil {
		t.Fatal(err)
	}
	if !imported.Identity.OmitDeviceHeaders {
		t.Fatal("transfer lost opt-out")
	}
	identity.OmitDeviceHeaders = false
	if headers(identity)["x-hwid"] != identity.HWID {
		t.Fatal("default headers lost")
	}
}
