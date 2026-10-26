package main

import "fmt"

type zapretResume struct {
	Folder, Strategy string
}

type vpnCompanion interface {
	vpnState() (running, busy bool, resume zapretResume)
	stopProcess() error
	Start(folder, strategy string) error
}

type vpnHandoff struct {
	paused *zapretResume
}

func (z *Zapret) vpnState() (bool, bool, zapretResume) {
	z.mu.Lock()
	defer z.mu.Unlock()
	folder := ""
	if z.app != nil {
		folder = z.app.localSettings().ZapretFolder
	}
	return z.cmd != nil, z.job.Busy, zapretResume{z.effectiveFolderLocked(folder), z.strategy}
}

func vpnConflict(z vpnCompanion, external func() bool) string {
	if z != nil {
		running, busy, _ := z.vpnState()
		if busy {
			return "busy"
		}
		if running {
			return "managed"
		}
	}
	if external() {
		return "external"
	}
	return ""
}

func (h *vpnHandoff) prepare(z vpnCompanion, allow bool, external func() bool) error {
	switch vpnConflict(z, external) {
	case "busy":
		return fail(409, "Дождитесь завершения задачи zapret или остановите её во вкладке zapret.")
	case "external":
		return fail(409, "Обнаружен сторонний zapret (winws). Остановите его через прежний лаунчер или службу и повторите подключение.")
	case "managed":
		if !allow {
			return fail(409, "Перед TUN нужно приостановить zapret. Разрешите переключение в настройках SVOI.")
		}
		_, _, resume := z.vpnState()
		if err := z.stopProcess(); err != nil {
			return err
		}
		h.paused = &resume
		if external() {
			return fail(409, "SVOI приостановил свой zapret, но обнаружен ещё один winws. Остановите сторонний zapret и повторите подключение.")
		}
	}
	return nil
}

func (h *vpnHandoff) restore(z vpnCompanion) error {
	if h.paused == nil || z == nil {
		return nil
	}
	running, _, _ := z.vpnState()
	if running {
		h.paused = nil
		return nil
	}
	if err := z.Start(h.paused.Folder, h.paused.Strategy); err != nil {
		return fmt.Errorf("Не удалось вернуть zapret: %w. Повторите отключение или запустите стратегию во вкладке zapret", err)
	}
	h.paused = nil
	return nil
}

func (a *App) companion() vpnCompanion {
	if a.zapret == nil {
		return nil
	}
	return a.zapret
}
