package main

import (
	"errors"
	"net/http/httptest"
	"testing"
)

type fakeCompanion struct {
	running, busy bool
	resume        zapretResume
	stops, starts int
	err           error
	stopErr       error
}

func (z *fakeCompanion) vpnState() (bool, bool, zapretResume) { return z.running, z.busy, z.resume }
func (z *fakeCompanion) stopProcess() error {
	if z.stopErr != nil {
		return z.stopErr
	}
	z.running = false
	z.stops++
	return nil
}
func (z *fakeCompanion) Start(folder, strategy string) error {
	z.starts++
	if z.err != nil {
		return z.err
	}
	z.running = true
	z.resume = zapretResume{folder, strategy}
	return nil
}

func TestVPNHandoffRestoresExactlyPausedStrategy(t *testing.T) {
	z := &fakeCompanion{running: true, resume: zapretResume{"folder", "general.bat"}}
	h := vpnHandoff{}
	if h.prepare(z, false, func() bool { return false }) == nil || z.stops != 0 {
		t.Fatal("paused without consent")
	}
	if err := h.prepare(z, true, func() bool { return false }); err != nil {
		t.Fatal(err)
	}
	if z.running || h.paused == nil {
		t.Fatal("not paused")
	}
	if err := h.prepare(z, true, func() bool { return false }); err != nil {
		t.Fatal(err)
	}
	if z.stops != 1 {
		t.Fatal("reconnect lost original pause")
	}
	z.resume = zapretResume{"other", "general-new.bat"}
	if err := h.restore(z); err != nil {
		t.Fatal(err)
	}
	if z.resume.Strategy != "general.bat" || h.paused != nil {
		t.Fatal("restored wrong strategy")
	}
	_ = h.restore(z)
	if z.starts != 1 {
		t.Fatal("duplicate resume")
	}
}

func TestVPNHandoffDoesNotProceedAfterStopFailure(t *testing.T) {
	z := &fakeCompanion{running: true, stopErr: errors.New("access denied")}
	h := vpnHandoff{}
	if h.prepare(z, true, func() bool { return false }) == nil || !z.running || h.paused != nil {
		t.Fatal("failed stop treated as paused")
	}
}

func TestPausedZapretRejectsUpdatingItsRestoreFiles(t *testing.T) {
	a := newTestApp(t)
	a.handoff.paused = &zapretResume{Folder: "saved", Strategy: "general.bat"}
	z := &Zapret{app: a}
	for _, path := range []string{"/api/zapret/job", "/api/zapret/select"} {
		err := z.API(httptest.NewRecorder(), httptest.NewRequest("POST", path, nil), "")
		if e, ok := err.(apiError); !ok || e.status != 409 {
			t.Fatalf("unexpected mutation: %v", err)
		}
	}
}
func TestVPNHandoffExternalAndBusyNeverStopped(t *testing.T) {
	for _, busy := range []bool{true, false} {
		z := &fakeCompanion{busy: busy}
		h := vpnHandoff{}
		if h.prepare(z, true, func() bool { return true }) == nil || z.stops != 0 || h.paused != nil {
			t.Fatal("external process touched")
		}
	}
}
func TestVPNHandoffRetainsFailedResumeForRetry(t *testing.T) {
	z := &fakeCompanion{running: true, resume: zapretResume{"folder", "general.bat"}}
	h := vpnHandoff{}
	_ = h.prepare(z, true, func() bool { return false })
	z.err = errors.New("start failed")
	if h.restore(z) == nil || h.paused == nil {
		t.Fatal("lost retry state")
	}
	z.err = nil
	if err := h.restore(z); err != nil || h.paused != nil {
		t.Fatal(err)
	}
}
func TestVPNHandoffDetectsSecondWinwsAfterPause(t *testing.T) {
	z := &fakeCompanion{running: true, resume: zapretResume{"folder", "general.bat"}}
	h := vpnHandoff{}
	if h.prepare(z, true, func() bool { return true }) == nil || h.paused == nil {
		t.Fatal("second process not detected")
	}
}
