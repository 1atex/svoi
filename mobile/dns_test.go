package mobile

import (
	"encoding/json"
	"testing"
	"time"
)

func TestDNSRequestCancelledBeforeRunDoesNotMeasure(t *testing.T) {
	s, err := NewSession(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	token := speedCall(t, s, "POST", "/api/groups", "", map[string]string{"name": "DNS", "deviceName": "Test", "platform": "Android"}, 201)["token"].(string)
	request := s.NewDNSRequest(token, `{"address":"127.0.0.1"}`)
	request.Cancel()
	started := time.Now()
	var response struct{ Status int }
	if err := json.Unmarshal([]byte(request.Run()), &response); err != nil || response.Status == 200 || time.Since(started) > time.Second {
		t.Fatalf("cancelled request was measured: %+v, %v", response, err)
	}
	if err := json.Unmarshal([]byte(request.Run()), &response); err != nil || response.Status != 409 {
		t.Fatal("request was reused")
	}
}
