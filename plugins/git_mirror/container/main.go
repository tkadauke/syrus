// Command git-mirror keeps bare mirrors of the git repositories Syrus works
// on and answers file, tree, and diff reads from them, so Syrus does not have
// to ask the hosting platform's API for each one.
//
// It holds no long-lived secrets. Syrus pushes each repository's fetch URL and
// a short-lived credential on every sync tick; credentials live in memory
// only. The mirrors themselves persist on the /data volume.
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/tkadauke/syrus/plugins/git_mirror/container/internal/gitexec"
	"github.com/tkadauke/syrus/plugins/git_mirror/container/internal/mirror"
	"github.com/tkadauke/syrus/plugins/git_mirror/container/internal/server"
)

const minTokenLength = 32

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	if err := run(); err != nil {
		log.Fatalf("git-mirror: %v", err)
	}
}

func run() error {
	token := os.Getenv("GIT_MIRROR_TOKEN")
	if len(token) < minTokenLength {
		return fmt.Errorf("GIT_MIRROR_TOKEN must be set to at least %d characters", minTokenLength)
	}
	syncInterval, err := durationEnv("GIT_MIRROR_SYNC_INTERVAL", 30*time.Second)
	if err != nil {
		return err
	}
	fetchTimeout, err := durationEnv("GIT_MIRROR_FETCH_TIMEOUT", 10*time.Minute)
	if err != nil {
		return err
	}

	store, err := mirror.Open(mirror.Config{
		DataDir:      envOr("GIT_MIRROR_DATA_DIR", "/data"),
		SyncInterval: syncInterval,
		FetchTimeout: fetchTimeout,
		Git:          gitexec.Runner{Home: envOr("GIT_MIRROR_HOME", "/tmp")},
	})
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go store.Run(ctx)

	srv := &http.Server{
		Addr:              envOr("GIT_MIRROR_LISTEN", ":8080"),
		Handler:           server.New(store, token),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	log.Printf("git-mirror: listening on %s, syncing every %s", srv.Addr, syncInterval)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

// healthcheck lets the image's HEALTHCHECK work without curl or wget.
func healthcheck() int {
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1" + envOr("GIT_MIRROR_LISTEN", ":8080") + "/healthz")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func durationEnv(key string, fallback time.Duration) (time.Duration, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("%s must be a positive duration like 30s", key)
	}
	return d, nil
}
