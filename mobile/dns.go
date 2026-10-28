package mobile

import (
	"context"
	"sync"
)

type DNSRequest struct {
	ctx         context.Context
	cancel      context.CancelFunc
	session     *Session
	token, body string
	once        sync.Once
}

func (s *Session) NewDNSRequest(token, body string) *DNSRequest {
	ctx, cancel := context.WithCancel(context.Background())
	return &DNSRequest{ctx: ctx, cancel: cancel, session: s, token: token, body: body}
}

func (d *DNSRequest) Cancel() { d.cancel() }

func (d *DNSRequest) Run() string {
	result := `{"status":409,"body":{"error":"Проверка уже завершена"}}`
	d.once.Do(func() {
		defer d.cancel()
		result = d.session.app.RequestContext(d.ctx, "POST", "/api/dns/benchmark", d.token, d.body)
	})
	return result
}
