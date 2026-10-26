package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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
var setupSlots = make(chan struct{}, 2)

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
	options := p.session.app.ProbeOptions()
	config, err := p.session.app.ProbeConfig(p.token, p.serverID)
	if err != nil {
		return 0, err
	}
	latency, err := probeConfigWithTimeout(p.ctx, config, options.URL, time.Duration(options.TimeoutSeconds)*time.Second)
	if err := p.ctx.Err(); err != nil {
		return 0, err
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return 0, fmt.Errorf("Нет ответа за %d с. Подключение вручную доступно.", options.TimeoutSeconds)
	}
	if err != nil {
		return 0, err
	}
	return latency, nil
}

func probeConfig(ctx context.Context, raw, target string) (int64, error) {
	return probeConfigWithTimeout(ctx, raw, target, 4*time.Second)
}

func probeConfigWithTimeout(parent context.Context, raw, target string, timeout time.Duration) (int64, error) {
	ctx, cancelSetup := context.WithTimeout(parent, 5*time.Second)
	defer cancelSetup()
	if err := ctx.Err(); err != nil {
		return 0, err
	}
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
	x, err := startProbeCore(ctx, string(data))
	if err != nil {
		return 0, fmt.Errorf("Подготовка ядра: %v", err)
	}
	defer x.Close()
	cancelSetup()
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	started := time.Now()
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
	if response != nil {
		defer response.Body.Close()
	}
	if cancelled := ctx.Err(); cancelled != nil {
		return 0, cancelled
	}
	if err != nil {
		return 0, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return 0, errors.New("неожиданный ответ проверки")
	}
	return time.Since(started).Milliseconds(), nil
}

func startProbeCore(ctx context.Context, raw string) (*core.Instance, error) {
	select {
	case setupSlots <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	type result struct {
		core *core.Instance
		err  error
	}
	ready := make(chan result)
	go func() {
		defer func() { <-setupSlots }()
		loaded, err := core.LoadConfig("json", strings.NewReader(raw))
		var x *core.Instance
		if err == nil {
			x, err = core.New(loaded)
		}
		if err == nil {
			err = x.Start()
		}
		if err != nil && x != nil {
			x.Close()
			x = nil
		}
		select {
		case ready <- result{x, err}:
		case <-ctx.Done():
			if x != nil {
				x.Close()
			}
		}
	}()
	select {
	case r := <-ready:
		return r.core, r.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
