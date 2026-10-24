package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
)

var probeSlots = make(chan struct{}, 2)

type ProbeRequest struct {
	ctx             context.Context
	cancel          context.CancelFunc
	session         *Session
	token, serverID string
	once            sync.Once
}

func (s *Session) NewProbe(token, serverID string) *ProbeRequest {
	ctx, cancel := context.WithCancel(context.Background())
	return &ProbeRequest{ctx: ctx, cancel: cancel, session: s, token: token, serverID: serverID}
}

func (p *ProbeRequest) Cancel() { p.cancel() }

func (p *ProbeRequest) Run() (int64, error) {
	var latency int64
	err := errors.New("Проверка уже завершена")
	p.once.Do(func() { latency, err = p.run() })
	return latency, err
}

func (s *Session) Probe(token, serverID string) (int64, error) {
	return s.NewProbe(token, serverID).Run()
}

func (p *ProbeRequest) run() (int64, error) {
	defer p.cancel()
	if err := p.ctx.Err(); err != nil {
		return 0, err
	}
	select {
	case probeSlots <- struct{}{}:
		defer func() { <-probeSlots }()
	default:
		return 0, errors.New("Оба слота проверки заняты. Повторите через несколько секунд.")
	}
	ctx, cancel := context.WithTimeout(p.ctx, 4*time.Second)
	defer cancel()
	config, err := p.session.app.ProbeConfig(p.token, p.serverID)
	if err != nil {
		return 0, err
	}
	latency, err := probeConfig(ctx, config, "https://www.gstatic.com/generate_204")
	if ctx.Err() != nil {
		return 0, errors.New("Нет ответа за 4 секунды. Подключение вручную доступно.")
	}
	if err != nil {
		return 0, errors.New("Профиль не прошёл HTTPS-проверку. Сервер, маршрут или адрес проверки недоступен.")
	}
	return latency, nil
}

func probeConfig(ctx context.Context, raw, target string) (int64, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	started := time.Now()
	var config map[string]any
	if err := json.Unmarshal([]byte(raw), &config); err != nil {
		return 0, err
	}
	tag := ""
	inbounds, _ := config["inbounds"].([]any)
	for _, value := range inbounds {
		inbound, _ := value.(map[string]any)
		if inbound["protocol"] == "http" {
			tag, _ = inbound["tag"].(string)
			break
		}
	}
	config["inbounds"] = []any{}
	config["log"] = map[string]any{"loglevel": "none"}
	data, err := json.Marshal(config)
	if err != nil {
		return 0, err
	}
	loaded, err := core.LoadConfig("json", strings.NewReader(string(data)))
	if err != nil {
		return 0, err
	}
	if err = ctx.Err(); err != nil {
		return 0, err
	}
	x, err := core.New(loaded)
	if err != nil {
		return 0, err
	}
	defer x.Close()
	if err = x.Start(); err != nil {
		return 0, err
	}
	if err = ctx.Err(); err != nil {
		return 0, err
	}
	transport := &http.Transport{
		Proxy: nil, DisableKeepAlives: true,
		DialContext: func(_ context.Context, network, address string) (net.Conn, error) {
			dest, err := xnet.ParseDestination("tcp:" + address)
			if err != nil {
				return nil, err
			}
			// HTTP transport detaches its dial context; Xray must retain the probe's cancellation.
			dialContext := session.ContextWithInbound(ctx, &session.Inbound{Tag: tag, Name: "http"})
			return core.Dial(dialContext, x, dest)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequestWithContext(ctx, "GET", target, nil)
	if err != nil {
		return 0, err
	}
	response, err := client.Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return 0, errors.New("неожиданный ответ проверки")
	}
	return time.Since(started).Milliseconds(), nil
}
