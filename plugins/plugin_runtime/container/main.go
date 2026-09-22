// Command runtime-manager starts, stops and reports on plugin-owned containers
// for a Docker Compose install of Syrus.
//
// It is the only process in the stack with access to the Docker socket. Syrus
// itself never touches Docker: it asks this service, over the project network,
// to run a plugin's declared service, and the policy package decides whether
// the request is allowed. See internal/policy for why that check lives here
// rather than in Syrus.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/docker"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/manager"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/policy"
	"github.com/tkadauke/syrus/plugins/plugin_runtime/container/internal/server"
)

const (
	defaultListen   = ":8080"
	defaultSocket   = "/var/run/docker.sock"
	defaultPrefixes = "ghcr.io/tkadauke/"
	minTokenLength  = 32
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	if err := run(); err != nil {
		log.Fatalf("runtime-manager: %v", err)
	}
}

func run() error {
	token := os.Getenv("RUNTIME_MANAGER_TOKEN")
	if len(token) < minTokenLength {
		// Anything on the project network can reach this service. Refusing to
		// start without a real token is better than starting open.
		return fmt.Errorf("RUNTIME_MANAGER_TOKEN must be set to at least %d characters", minTokenLength)
	}

	client := docker.New(envOr("DOCKER_SOCKET", defaultSocket))
	project, network, err := discover(client)
	if err != nil {
		return err
	}

	prefixes := strings.Split(envOr("RUNTIME_MANAGER_ALLOWED_IMAGE_PREFIXES", defaultPrefixes), ",")
	pol := policy.New(prefixes)
	if len(pol.Allowed()) == 0 {
		return errors.New("RUNTIME_MANAGER_ALLOWED_IMAGE_PREFIXES allows no images")
	}

	mgr := manager.New(client, pol, project, network)
	handler := server.New(mgr, token, server.Info{Project: project, Network: network, AllowedPrefixes: pol.Allowed()})

	listen := envOr("RUNTIME_MANAGER_LISTEN", defaultListen)
	srv := &http.Server{Addr: listen, Handler: handler, ReadHeaderTimeout: 10 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
		// Take the plugin containers down with the manager, keeping their
		// volumes, so `docker compose down` can remove the project network.
		// The Compose file gives the manager a stop grace period long enough
		// for this.
		stopping, cancelStop := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancelStop()
		if err := mgr.StopAll(stopping); err != nil {
			log.Printf("runtime-manager: stopping plugin services: %v", err)
		}
	}()

	log.Printf("runtime-manager: project=%s network=%s allowed=%v listening on %s", project, network, pol.Allowed(), listen)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	// ListenAndServe returns as soon as shutdown begins; wait for the plugin
	// containers to be taken down before exiting.
	<-stopped
	return nil
}

// discover finds the Compose project and network to place services on. Inside
// Compose it inspects its own container: the hostname is the container id, and
// Compose labels the container with its project. That keeps the manager
// correct for installs whose project is not "syrus" -- install.sh supports
// per-channel project names -- without anyone having to configure it.
func discover(client *docker.Client) (string, string, error) {
	project := os.Getenv("RUNTIME_MANAGER_PROJECT")
	network := os.Getenv("RUNTIME_MANAGER_NETWORK")
	if project != "" && network != "" {
		return project, network, nil
	}

	host, err := os.Hostname()
	if err != nil {
		return "", "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	self, err := client.InspectContainer(ctx, host)
	if err != nil {
		return "", "", fmt.Errorf("could not inspect own container %q to discover the project; set RUNTIME_MANAGER_PROJECT and RUNTIME_MANAGER_NETWORK: %w", host, err)
	}
	if project == "" {
		project = self.Config.Labels["com.docker.compose.project"]
	}
	if network == "" {
		network = pickNetwork(self.NetworkSettings.Networks, project)
	}
	if project == "" || network == "" {
		return "", "", errors.New("could not discover project and network; set RUNTIME_MANAGER_PROJECT and RUNTIME_MANAGER_NETWORK")
	}
	return project, network, nil
}

// pickNetwork prefers the project's default network, which is the one Syrus's
// web and worker containers are also on.
func pickNetwork[T any](networks map[string]T, project string) string {
	if _, ok := networks[project+"_default"]; ok {
		return project + "_default"
	}
	names := make([]string, 0, len(networks))
	for name := range networks {
		names = append(names, name)
	}
	sort.Strings(names)
	if len(names) > 0 {
		return names[0]
	}
	return ""
}

// healthcheck is the container's HEALTHCHECK. The image is distroless, with no
// curl or wget, so the binary checks itself.
func healthcheck() int {
	listen := envOr("RUNTIME_MANAGER_LISTEN", defaultListen)
	port := listen[strings.LastIndex(listen, ":")+1:]
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
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
