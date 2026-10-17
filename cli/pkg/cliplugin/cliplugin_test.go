package cliplugin

import "testing"

func TestExitStatusErrorNormalizesProcessStatus(t *testing.T) {
	tests := map[int]int{
		-1:  1,
		0:   1,
		37:  37,
		300: 255,
	}

	for status, want := range tests {
		if got := (ExitStatusError{Status: status}).ExitStatus(); got != want {
			t.Fatalf("ExitStatusError{%d}.ExitStatus() = %d, want %d", status, got, want)
		}
	}
}
