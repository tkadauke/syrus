package cmd

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/spf13/cobra"
)

var newPluginDevContainer = func() pluginDevContainer { return &dockerPluginDevContainer{} }
var newPluginDevWatcher = func(root string) pluginDevWatcher { return newPollingPluginDevWatcher(root) }

type pluginDevAction int

const (
	pluginDevIgnore pluginDevAction = iota
	pluginDevRebuildFrontend
	pluginDevRestartApp
)

type pluginDevOptions struct {
	Directory, Image, Name string
	KeepData               bool
}

type pluginDevHealth struct {
	State   string   `json:"state"`
	Reasons []string `json:"reasons"`
}

type pluginDevContainer interface {
	Available() error
	Pull(context.Context, string, io.Writer, io.Writer) error
	Start(context.Context, pluginDevOptions, io.Writer, io.Writer) (string, error)
	RebuildFrontend(context.Context, io.Writer, io.Writer) error
	Restart(context.Context, io.Writer, io.Writer) error
	Health(context.Context) (pluginDevHealth, error)
	Stop(context.Context, bool, io.Writer, io.Writer) error
}

type pluginDevWatcher interface {
	Changes(context.Context) (<-chan []string, <-chan error)
}

func newPluginDevCommand() *cobra.Command {
	var version string
	var keepData bool
	command := &cobra.Command{
		Use:   "dev [DIR]",
		Short: "Run a throwaway Syrus that reloads a local plugin",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(command *cobra.Command, args []string) error {
			directory := "."
			if len(args) == 1 {
				directory = args[0]
			}
			absolute, err := readablePluginDirectory(directory)
			if err != nil {
				return err
			}
			selected := version
			if selected == "" {
				selected = resolveConnectedInstanceVersion(command.Context())
			}
			if selected == "" {
				selected = cliReleaseVersion
			}
			container := newPluginDevContainer()
			if err := container.Available(); err != nil {
				return err
			}
			image := pluginTestImage + ":" + strings.TrimPrefix(selected, "v")
			if err := container.Pull(command.Context(), image, command.OutOrStdout(), command.ErrOrStderr()); err != nil {
				return err
			}
			name, err := pluginDevName(absolute)
			if err != nil {
				return err
			}
			url, err := container.Start(command.Context(), pluginDevOptions{Directory: absolute, Image: image, Name: name, KeepData: keepData}, command.OutOrStdout(), command.ErrOrStderr())
			if err != nil {
				return err
			}
			defer container.Stop(context.Background(), keepData, command.OutOrStdout(), command.ErrOrStderr())
			fmt.Fprintf(command.OutOrStdout(), "Syrus plugin dev: %s\nSign in with demo@syrus.local / password\n", url)
			health, healthErr := container.Health(command.Context())
			printPluginDevHealth(command.OutOrStdout(), health, healthErr)
			watchContext, stopSignals := signal.NotifyContext(command.Context(), os.Interrupt)
			defer stopSignals()
			return runPluginDevLoop(watchContext, newPluginDevWatcher(absolute), container, command.OutOrStdout(), command.ErrOrStderr())
		},
	}
	command.Flags().StringVar(&version, "syrus-version", "", "Syrus release to run against")
	command.Flags().BoolVar(&keepData, "keep-data", false, "keep the instance data volume after shutdown")
	return command
}

func pluginDevName(directory string) (string, error) {
	gemspecs, err := filepath.Glob(filepath.Join(directory, "*.gemspec"))
	if err != nil {
		return "", err
	}
	if len(gemspecs) != 1 {
		return "", fmt.Errorf("plugin directory must contain exactly one .gemspec; found %d", len(gemspecs))
	}
	return strings.TrimSuffix(filepath.Base(gemspecs[0]), ".gemspec"), nil
}

func readablePluginDirectory(directory string) (string, error) {
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(absolute)
	if err != nil || !info.IsDir() {
		return "", fmt.Errorf("plugin directory is not readable: %s", absolute)
	}
	return absolute, nil
}

func runPluginDevLoop(ctx context.Context, watcher pluginDevWatcher, container pluginDevContainer, stdout, stderr io.Writer) error {
	changes, watchErrors := watcher.Changes(ctx)
	for {
		select {
		case <-ctx.Done():
			return nil
		case err, ok := <-watchErrors:
			if ok && err != nil {
				return err
			}
			watchErrors = nil
		case paths, ok := <-changes:
			if !ok {
				return nil
			}
			action := pluginDevActionForPaths(paths)
			switch action {
			case pluginDevRestartApp:
				fmt.Fprintln(stdout, "Plugin backend changed; restarting Syrus...")
				if err := container.Restart(ctx, stdout, stderr); err != nil {
					fmt.Fprintf(stderr, "Restart failed: %v\n", err)
					continue
				}
				health, healthErr := container.Health(ctx)
				printPluginDevHealth(stdout, health, healthErr)
			case pluginDevRebuildFrontend:
				fmt.Fprintln(stdout, "Plugin frontend changed; rebuilding...")
				if err := container.RebuildFrontend(ctx, stdout, stderr); err != nil {
					fmt.Fprintf(stderr, "Frontend build failed: %v\n", err)
					continue
				}
				fmt.Fprintln(stdout, "Frontend rebuilt; reload the browser to use the new bundle.")
			}
		}
	}
}

func pluginDevActionForPaths(paths []string) pluginDevAction {
	action := pluginDevIgnore
	for _, path := range paths {
		path = filepath.ToSlash(path)
		base := filepath.Base(path)
		if strings.HasSuffix(path, ".rb") || strings.HasSuffix(path, ".gemspec") || base == "manifest.json" || strings.HasPrefix(path, "locales/") || strings.Contains(path, "/locales/") {
			return pluginDevRestartApp
		}
		if strings.HasPrefix(path, "frontend/") && !strings.HasPrefix(path, "frontend/dist/") {
			action = pluginDevRebuildFrontend
		}
	}
	return action
}

func printPluginDevHealth(out io.Writer, health pluginDevHealth, err error) {
	if err != nil {
		fmt.Fprintf(out, "Plugin health: unavailable (%v)\n", err)
		return
	}
	fmt.Fprintf(out, "Plugin health: %s", health.State)
	if len(health.Reasons) > 0 {
		fmt.Fprintf(out, " — %s", strings.Join(health.Reasons, "; "))
	}
	fmt.Fprintln(out)
}

type pollingPluginDevWatcher struct {
	root               string
	interval, debounce time.Duration
}

func newPollingPluginDevWatcher(root string) *pollingPluginDevWatcher {
	return &pollingPluginDevWatcher{root: root, interval: 150 * time.Millisecond, debounce: 350 * time.Millisecond}
}

func (watcher *pollingPluginDevWatcher) Changes(ctx context.Context) (<-chan []string, <-chan error) {
	changes := make(chan []string)
	errorsChannel := make(chan error, 1)
	go func() {
		defer close(changes)
		defer close(errorsChannel)
		previous, err := pluginDevSnapshot(watcher.root)
		if err != nil {
			errorsChannel <- err
			return
		}
		ticker := time.NewTicker(watcher.interval)
		defer ticker.Stop()
		pending := map[string]struct{}{}
		var timer *time.Timer
		var timerChannel <-chan time.Time
		for {
			select {
			case <-ctx.Done():
				if timer != nil {
					timer.Stop()
				}
				return
			case <-ticker.C:
				current, snapshotErr := pluginDevSnapshot(watcher.root)
				if snapshotErr != nil {
					errorsChannel <- snapshotErr
					return
				}
				newChanges := pluginDevSnapshotChanges(previous, current)
				for _, path := range newChanges {
					pending[path] = struct{}{}
				}
				previous = current
				if len(newChanges) > 0 {
					if timer != nil {
						timer.Stop()
					}
					timer = time.NewTimer(watcher.debounce)
					timerChannel = timer.C
				}
			case <-timerChannel:
				paths := make([]string, 0, len(pending))
				for path := range pending {
					paths = append(paths, path)
				}
				sort.Strings(paths)
				pending = map[string]struct{}{}
				timerChannel = nil
				select {
				case changes <- paths:
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return changes, errorsChannel
}

type pluginDevFileState struct{ size, modified int64 }

func pluginDevSnapshot(root string) (map[string]pluginDevFileState, error) {
	result := map[string]pluginDevFileState{}
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if relative != "." && (entry.Name() == ".git" || entry.Name() == "node_modules" || strings.HasPrefix(filepath.ToSlash(relative), "dist/")) {
				return filepath.SkipDir
			}
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		result[filepath.ToSlash(relative)] = pluginDevFileState{size: info.Size(), modified: info.ModTime().UnixNano()}
		return nil
	})
	return result, err
}

func pluginDevSnapshotChanges(before, after map[string]pluginDevFileState) []string {
	changed := []string{}
	for path, state := range after {
		if old, ok := before[path]; !ok || old != state {
			changed = append(changed, path)
		}
	}
	for path := range before {
		if _, ok := after[path]; !ok {
			changed = append(changed, path)
		}
	}
	return changed
}

type dockerPluginDevContainer struct {
	mu                sync.Mutex
	container, volume string
	pluginName        string
	hostUser          string
}

func (container *dockerPluginDevContainer) Available() error {
	if _, err := exec.LookPath("docker"); err != nil {
		return errors.New("Docker is required for plugin development")
	}
	return exec.Command("docker", "info").Run()
}

func (container *dockerPluginDevContainer) Pull(ctx context.Context, image string, stdout, stderr io.Writer) error {
	command := exec.CommandContext(ctx, "docker", "pull", image)
	command.Stdout, command.Stderr = stdout, stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("could not pull Syrus image %s: %w", image, err)
	}
	return nil
}

func (container *dockerPluginDevContainer) Start(ctx context.Context, options pluginDevOptions, stdout, stderr io.Writer) (string, error) {
	suffix, err := randomPluginDevSuffix()
	if err != nil {
		return "", err
	}
	container.container = "syrus-plugin-dev-" + suffix
	container.volume = container.container + "-data"
	container.pluginName = options.Name
	if currentUser, userErr := user.Current(); userErr == nil && runtime.GOOS != "windows" {
		container.hostUser = currentUser.Uid + ":" + currentUser.Gid
	}
	if err := runDocker(ctx, stdout, stderr, "volume", "create", container.volume); err != nil {
		return "", err
	}
	secret, err := randomPluginDevSuffix()
	if err != nil {
		return "", err
	}
	pluginMount := "/plugins/" + options.Name
	seed := `bin/rails db:prepare && bin/rails runner 'u=User.find_or_initialize_by(email_address:"demo@syrus.local");u.assign_attributes(name:"Demo Plugin Author",global_role:"admin");u.password="password";u.save!;p=PluginRecord.find_or_initialize_by(name:ENV.fetch("SYRUS_DEV_PLUGIN_NAME"));p.enabled=true;p.save!' && exec ./bin/thrust ./bin/rails server`
	args := []string{"run", "-d", "--name", container.container, "-p", "127.0.0.1::80",
		"-v", options.Directory + ":" + pluginMount, "-v", container.volume + ":/home/rails/.syrus",
		"-e", "SYRUS_SQLITE=1", "-e", "SYRUS_DATA_ROOT=/home/rails/.syrus", "-e", "SEARCH_DATABASE_PATH=/home/rails/.syrus/search.sqlite3",
		"-e", "SYRUS_PLUGIN_PATH=/plugins", "-e", "SYRUS_DEV_PLUGIN_NAME=" + options.Name, "-e", "SYRUS_APP_HOST=localhost", "-e", "SYRUS_ASSUME_SSL=false", "-e", "SYRUS_FORCE_SSL=false", "-e", "RAILS_ENV=production",
		"-e", "SECRET_KEY_BASE=" + secret + secret, "-e", "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=" + secret,
		"-e", "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=" + secret, "-e", "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=" + secret,
		"--entrypoint", "/bin/bash", options.Image, "-lc", seed}
	if err := runDocker(ctx, stdout, stderr, args...); err != nil {
		container.Stop(context.Background(), options.KeepData, stdout, stderr)
		return "", err
	}
	if err := container.waitReady(ctx); err != nil {
		container.logs(context.Background(), stderr)
		_ = container.Stop(context.Background(), options.KeepData, stdout, stderr)
		return "", err
	}
	output, err := dockerOutput(ctx, "port", container.container, "80/tcp")
	if err != nil {
		_ = container.Stop(context.Background(), options.KeepData, stdout, stderr)
		return "", err
	}
	parts := strings.Split(strings.TrimSpace(output), ":")
	return "http://127.0.0.1:" + parts[len(parts)-1], nil
}

func (container *dockerPluginDevContainer) RebuildFrontend(ctx context.Context, stdout, stderr io.Writer) error {
	if err := runDocker(ctx, stdout, stderr, "exec", container.container, "/bin/bash", "-lc", "test -d /rails/node_modules || npm ci"); err != nil {
		return err
	}
	args := []string{"exec"}
	if container.hostUser != "" {
		args = append(args, "--user", container.hostUser)
	}
	args = append(args, container.container, "node", "/rails/bin/build-plugin-frontend", "/plugins/"+container.pluginName)
	return runDocker(ctx, stdout, stderr, args...)
}

func (container *dockerPluginDevContainer) Restart(ctx context.Context, stdout, stderr io.Writer) error {
	if err := runDocker(ctx, stdout, stderr, "restart", container.container); err != nil {
		return err
	}
	return container.waitReady(ctx)
}

func (container *dockerPluginDevContainer) Health(ctx context.Context) (pluginDevHealth, error) {
	script := fmt.Sprintf(`m=Syrus::PluginRegistry.all_plugins.find{|x|x.name==%q};s=Syrus::PluginRegistry.health.status(%q);puts({state:(m ? (s ? s.state : :ok) : :not_loaded),reasons:(s ? s.reasons : [])}.to_json)`, container.pluginName, container.pluginName)
	output, err := dockerOutput(ctx, "exec", container.container, "bin/rails", "runner", script)
	if err != nil {
		return pluginDevHealth{}, err
	}
	var health pluginDevHealth
	if err := json.Unmarshal([]byte(strings.TrimSpace(output)), &health); err != nil {
		return pluginDevHealth{}, err
	}
	return health, nil
}

func (container *dockerPluginDevContainer) Stop(ctx context.Context, keepData bool, stdout, stderr io.Writer) error {
	container.mu.Lock()
	defer container.mu.Unlock()
	var result error
	if container.container != "" {
		result = runDocker(ctx, stdout, stderr, "rm", "-f", container.container)
		container.container = ""
	}
	if !keepData && container.volume != "" {
		if err := runDocker(ctx, stdout, stderr, "volume", "rm", container.volume); result == nil {
			result = err
		}
		container.volume = ""
	} else if keepData && container.volume != "" {
		fmt.Fprintf(stdout, "Kept Docker volume %s\n", container.volume)
	}
	return result
}

func (container *dockerPluginDevContainer) waitReady(ctx context.Context) error {
	deadline := time.NewTimer(90 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return errors.New("timed out waiting for the Syrus dev instance")
		case <-ticker.C:
			if exec.CommandContext(ctx, "docker", "exec", container.container, "curl", "-fsS", "http://127.0.0.1/readyz").Run() == nil {
				return nil
			}
		}
	}
}

func (container *dockerPluginDevContainer) logs(ctx context.Context, stderr io.Writer) {
	command := exec.CommandContext(ctx, "docker", "logs", container.container)
	command.Stdout, command.Stderr = stderr, stderr
	_ = command.Run()
}

func randomPluginDevSuffix() (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

func runDocker(ctx context.Context, stdout, stderr io.Writer, args ...string) error {
	command := exec.CommandContext(ctx, "docker", args...)
	command.Stdout, command.Stderr = stdout, stderr
	return command.Run()
}

func dockerOutput(ctx context.Context, args ...string) (string, error) {
	output, err := exec.CommandContext(ctx, "docker", args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("docker %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return string(output), nil
}
