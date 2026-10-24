package backend

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestZapretPresetParsing(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "folder with spaces")
	os.MkdirAll(dir, 0700)
	text := "@echo off\r\ncall service.bat check_updates\r\nstart \"zapret: %~n0\" /min \"%BIN%winws.exe\" --wf-tcp=80,443,%GameFilterTCP% ^\r\n --hostlist=\"%LISTS%list-general.txt\" --dpi-desync-fake-tls=\"%BIN%tls_clienthello.bin\" --new --filter-udp=443\r\n"
	file := filepath.Join(dir, "general.bat")
	os.WriteFile(file, []byte(text), 0600)
	args, err := parseZapretStrategy(dir, "general.bat")
	if err != nil {
		t.Fatal(err)
	}
	if len(args) != 5 || args[0] != "--wf-tcp=80,443,0" || args[1] != "--hostlist="+filepath.Join(dir, "lists", "list-general.txt") {
		t.Fatal(args)
	}
	for _, bad := range []string{"../general.bat", "service.bat", `..\general.bat`} {
		if _, err := parseZapretStrategy(dir, bad); err == nil {
			t.Fatal(bad)
		}
	}
	for _, suffix := range []string{" & calc.exe", " --bad=%UNSUPPORTED%", " --bad=\"unclosed"} {
		os.WriteFile(file, []byte(strings.TrimSpace(text)+suffix), 0600)
		if _, err := parseZapretStrategy(dir, "general.bat"); err == nil {
			t.Fatal(suffix)
		}
	}
}
