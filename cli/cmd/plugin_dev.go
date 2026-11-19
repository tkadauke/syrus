package cmd

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"
)

const pluginBackendImage = "ghcr.io/tkadauke/syrus-backend"

type pluginDevAction int

const (
	pluginDevIgnore pluginDevAction = iota
	pluginDevRebuild
	pluginDevRestart
)

type pluginDevRuntime interface {
	Available() error
	Pull(context.Context, string, io.Writer, io.Writer) error
	Start(context.Context, pluginDevRequest, io.Writer, io.Writer) (pluginDevInstance, error)
	BuildFrontend(context.Context, pluginDevInstance, io.Writer, io.Writer) error
	Restart(context.Context, pluginDevInstance, io.Writer, io.Writer) error
	Health(context.Context, pluginDevInstance) (string, error)
	Stop(context.Context, pluginDevInstance, bool, io.Writer, io.Writer) error
}

type pluginDevRequest struct {
	Directory string
	Image     string
}

type pluginDevInstance struct {
	Container, Volume, URL, PluginName, DirectoryName string
}

type pluginDevScanner interface {
	Snapshot(string) (map[string]pluginDevFile, error)
}

type pluginDevFile struct {
	Size    int64
	ModTime int64
}

type filesystemPluginDevScanner struct{}

func (filesystemPluginDevScanner) Snapshot(root string) (map[string]pluginDevFile, error) {
	result := map[string]pluginDevFile{}
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if entry.IsDir() && relative != "." && (entry.Name() == ".git" || entry.Name() == "node_modules" || relative == filepath.Join("dist", "frontend")) {
			return filepath.SkipDir
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		result[filepath.ToSlash(relative)] = pluginDevFile{Size: info.Size(), ModTime: info.ModTime().UnixNano()}
		return nil
	})
	return result, err
}

var newPluginDevRuntime = func() pluginDevRuntime { return dockerPluginDevRuntime{} }
var pluginDevScanInterval = 250 * time.Millisecond
var pluginDevDebounce = 500 * time.Millisecond

func newPluginDevCommand() *cobra.Command {
	var version string
	var keepData bool
	command := &cobra.Command{
		Use:   "dev [DIR]",
		Short: "Run a throwaway Syrus that reloads a plugin as you edit",
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
			runtime := newPluginDevRuntime()
			if err := runtime.Available(); err != nil {
				return err
			}
			image := pluginBackendImage + ":" + selectedPluginVersion(command.Context(), version)
			if err := runtime.Pull(command.Context(), image, command.OutOrStdout(), command.ErrOrStderr()); err != nil {
				return err
			}
			ctx, cancel := signal.NotifyContext(command.Context(), os.Interrupt, syscall.SIGTERM)
			defer cancel()
			instance, err := runtime.Start(ctx, pluginDevRequest{Directory: absolute, Image: image}, command.OutOrStdout(), command.ErrOrStderr())
			if err != nil {
				return err
			}
			defer func() {
				stopCtx, stopCancel := context.WithTimeout(context.Background(), 20*time.Second)
				defer stopCancel()
				_ = runtime.Stop(stopCtx, instance, keepData, command.OutOrStdout(), command.ErrOrStderr())
			}()
			fmt.Fprintf(command.OutOrStdout(), "Plugin development instance: %s\nSign in with demo@syrus.local / password\n", instance.URL)
			printPluginDevHealth(command.OutOrStdout(), runtime, instance)
			return watchPluginDev(ctx, absolute, runtime, instance, filesystemPluginDevScanner{}, command.OutOrStdout(), command.ErrOrStderr())
		},
	}
	command.Flags().StringVar(&version, "syrus-version", "", "Syrus release to run against")
	command.Flags().BoolVar(&keepData, "keep-data", false, "keep the instance's Docker volume after shutdown")
	return command
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

func pluginDevActionForPath(path string) pluginDevAction {
	path = filepath.ToSlash(path)
	if path == "frontend/entry.tsx" || strings.HasPrefix(path, "frontend/") || path == "package.json" || strings.HasPrefix(path, "package-lock.") {
		return pluginDevRebuild
	}
	if strings.HasSuffix(path, ".rb") || strings.HasSuffix(path, ".gemspec") || strings.HasSuffix(path, ".yml") || strings.HasSuffix(path, ".yaml") || strings.HasSuffix(path, ".json") {
		return pluginDevRestart
	}
	return pluginDevIgnore
}

func changedPluginDevPaths(before, after map[string]pluginDevFile) []string {
	changed := []string{}
	for path, current := range after {
		if previous, ok := before[path]; !ok || previous != current {
			changed = append(changed, path)
		}
	}
	for path := range before {
		if _, ok := after[path]; !ok {
			changed = append(changed, path)
		}
	}
	sort.Strings(changed)
	return changed
}

func watchPluginDev(ctx context.Context, directory string, runtime pluginDevRuntime, instance pluginDevInstance, scanner pluginDevScanner, stdout, stderr io.Writer) error {
	previous, err := scanner.Snapshot(directory)
	if err != nil {
		return err
	}
	ticker := time.NewTicker(pluginDevScanInterval)
	defer ticker.Stop()
	var timer *time.Timer
	var timerChannel <-chan time.Time
	pending := pluginDevIgnore
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			current, scanErr := scanner.Snapshot(directory)
			if scanErr != nil {
				fmt.Fprintf(stderr, "watch plugin directory: %v\n", scanErr)
				continue
			}
			changed := changedPluginDevPaths(previous, current)
			for _, path := range changed {
				action := pluginDevActionForPath(path)
				if action > pending {
					pending = action
				}
			}
			previous = current
			if pending != pluginDevIgnore && len(changed) > 0 {
				if timer == nil {
					timer = time.NewTimer(pluginDevDebounce)
				} else {
					if !timer.Stop() {
						select {
						case <-timer.C:
						default:
						}
					}
					timer.Reset(pluginDevDebounce)
				}
				timerChannel = timer.C
			}
		case <-timerChannel:
			action := pending
			pending, timerChannel = pluginDevIgnore, nil
			if action == pluginDevRestart {
				fmt.Fprintln(stdout, "Plugin source changed; restarting Syrus...")
				err = runtime.Restart(ctx, instance, stdout, stderr)
			} else {
				fmt.Fprintln(stdout, "Plugin frontend changed; rebuilding bundle...")
				err = runtime.BuildFrontend(ctx, instance, stdout, stderr)
				if err == nil {
					fmt.Fprintln(stdout, "Frontend rebuilt; reload the browser to use the new bundle.")
				}
			}
			if err != nil {
				fmt.Fprintf(stderr, "Plugin reload failed: %v\n", err)
			}
			printPluginDevHealth(stdout, runtime, instance)
		}
	}
}

func printPluginDevHealth(output io.Writer, runtime pluginDevRuntime, instance pluginDevInstance) {
	health, err := runtime.Health(context.Background(), instance)
	if err != nil {
		fmt.Fprintf(output, "Plugin health: unavailable (%v)\n", err)
		return
	}
	fmt.Fprintf(output, "Plugin health: %s\n", health)
}

type dockerPluginDevRuntime struct{}

func (dockerPluginDevRuntime) Available() error {
	if _, err := exec.LookPath("docker"); err != nil {
		return errors.New("Docker is required for plugin development")
	}
	return nil
}

func (dockerPluginDevRuntime) Pull(ctx context.Context, image string, stdout, stderr io.Writer) error {
	command := exec.CommandContext(ctx, "docker", "pull", image)
	command.Stdout, command.Stderr = stdout, stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("could not pull Syrus image %s: %w", image, err)
	}
	return nil
}

func randomPluginDevID() string {
	if value, err := randomPluginDevSecret(6); err == nil {
		return value
	}
	return fmt.Sprintf("%d", time.Now().UnixNano())
}

func randomPluginDevSecret(size int) (string, error) {
	bytes := make([]byte, size)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}

func availablePluginDevPort() (string, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	defer listener.Close()
	return fmt.Sprintf("%d", listener.Addr().(*net.TCPAddr).Port), nil
}

func (dockerPluginDevRuntime) Start(ctx context.Context, request pluginDevRequest, stdout, stderr io.Writer) (pluginDevInstance, error) {
	id := randomPluginDevID()
	port, err := availablePluginDevPort()
	if err != nil {
		return pluginDevInstance{}, err
	}
	instance := pluginDevInstance{Container: "syrus-plugin-dev-" + id, Volume: "syrus-plugin-dev-" + id, URL: "http://127.0.0.1:" + port, PluginName: filepath.Base(request.Directory), DirectoryName: filepath.Base(request.Directory)}
	secretKeyBase, err := randomPluginDevSecret(64)
	if err != nil {
		return instance, err
	}
	primaryKey, err := randomPluginDevSecret(32)
	if err != nil {
		return instance, err
	}
	deterministicKey, err := randomPluginDevSecret(32)
	if err != nil {
		return instance, err
	}
	derivationSalt, err := randomPluginDevSecret(32)
	if err != nil {
		return instance, err
	}
	started := false
	defer func() {
		if !started {
			cleanupCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			_ = runDockerCommand(cleanupCtx, io.Discard, io.Discard, "rm", "-f", instance.Container)
			_ = runDockerCommand(cleanupCtx, io.Discard, io.Discard, "volume", "rm", instance.Volume)
		}
	}()
	pluginTarget := "/plugins/" + instance.PluginName
	args := []string{"run", "-d", "--name", instance.Container, "-p", "127.0.0.1:" + port + ":80", "-v", instance.Volume + ":/home/rails/.syrus", "-v", request.Directory + ":" + pluginTarget,
		"-e", "DATABASE_URL=sqlite3:/home/rails/.syrus/plugin-dev.sqlite3", "-e", "SEARCH_DATABASE_PATH=/home/rails/.syrus/search.sqlite3", "-e", "SYRUS_PLUGIN_PATH=/plugins", "-e", "SYRUS_SQLITE=1",
		"-e", "SECRET_KEY_BASE=" + secretKeyBase, "-e", "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=" + primaryKey, "-e", "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=" + deterministicKey, "-e", "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=" + derivationSalt,
		"-e", "SYRUS_FORCE_SSL=false", "-e", "SYRUS_ASSUME_SSL=false", request.Image}
	if err := runDockerCommand(ctx, stdout, stderr, args...); err != nil {
		return instance, err
	}
	if err := waitPluginDevReady(ctx, instance.Container, 90*time.Second); err != nil {
		return instance, err
	}
	seed := `manifest=Syrus::PluginRegistry.all_plugins.find{|p| File.basename(p.plugin_root.to_s)==ENV.fetch("DEV_PLUGIN")}; abort "plugin manifest not found" unless manifest; PluginRecord.find_or_create_by!(name: manifest.name).update!(enabled: true); u=User.find_or_initialize_by(email_address:"demo@syrus.local"); u.assign_attributes(name:"Demo Operator",first_name:"Demo",last_name:"Operator",global_role:"admin"); u.password="password"; u.save!; puts "SYRUS_PLUGIN_DEV=#{manifest.name}"`
	seedOutput, err := exec.CommandContext(ctx, "docker", "exec", "-e", "DEV_PLUGIN="+instance.PluginName, instance.Container, "bin/rails", "runner", seed).CombinedOutput()
	if err != nil {
		return instance, fmt.Errorf("seed plugin development instance: %s: %w", strings.TrimSpace(string(seedOutput)), err)
	}
	instance.PluginName, err = markedPluginDevOutput(string(seedOutput))
	if err != nil {
		return instance, err
	}
	if err := runDockerCommand(ctx, stdout, stderr, "restart", instance.Container); err != nil {
		return instance, err
	}
	if err := waitPluginDevReady(ctx, instance.Container, 90*time.Second); err != nil {
		return instance, err
	}
	started = true
	return instance, nil
}

func waitPluginDevReady(ctx context.Context, container string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		command := exec.CommandContext(ctx, "docker", "exec", container, "curl", "-fsS", "http://127.0.0.1/readyz")
		if command.Run() == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	return errors.New("timed out waiting for the plugin development instance; inspect it with docker logs " + container)
}

func (dockerPluginDevRuntime) BuildFrontend(ctx context.Context, instance pluginDevInstance, stdout, stderr io.Writer) error {
	return runDockerCommand(ctx, stdout, stderr, "exec", "--user", fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()), instance.Container, "bin/build-plugin-frontend", "/plugins/"+instance.DirectoryName)
}

func (dockerPluginDevRuntime) Restart(ctx context.Context, instance pluginDevInstance, stdout, stderr io.Writer) error {
	if err := runDockerCommand(ctx, stdout, stderr, "restart", instance.Container); err != nil {
		return err
	}
	return waitPluginDevReady(ctx, instance.Container, 90*time.Second)
}

func (dockerPluginDevRuntime) Health(ctx context.Context, instance pluginDevInstance) (string, error) {
	healthCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	script := `s=Syrus::PluginRegistry.health.status(ENV.fetch("DEV_PLUGIN")); puts "SYRUS_PLUGIN_DEV=#{JSON.generate(state:s.state,reasons:s.reasons)}"`
	command := exec.CommandContext(healthCtx, "docker", "exec", "-e", "DEV_PLUGIN="+instance.PluginName, instance.Container, "bin/rails", "runner", script)
	output, err := command.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s", strings.TrimSpace(string(output)))
	}
	payload, err := markedPluginDevOutput(string(output))
	if err != nil {
		return "", err
	}
	var health struct {
		State   string   `json:"state"`
		Reasons []string `json:"reasons"`
	}
	if err := json.Unmarshal([]byte(payload), &health); err != nil {
		return "", err
	}
	if len(health.Reasons) > 0 {
		return health.State + " (" + strings.Join(health.Reasons, "; ") + ")", nil
	}
	return health.State, nil
}

func markedPluginDevOutput(output string) (string, error) {
	const marker = "SYRUS_PLUGIN_DEV="
	lines := strings.Split(strings.TrimSpace(output), "\n")
	for index := len(lines) - 1; index >= 0; index-- {
		if value, found := strings.CutPrefix(strings.TrimSpace(lines[index]), marker); found {
			return value, nil
		}
	}
	return "", fmt.Errorf("plugin development command returned no result: %s", strings.TrimSpace(output))
}

func (dockerPluginDevRuntime) Stop(ctx context.Context, instance pluginDevInstance, keepData bool, stdout, stderr io.Writer) error {
	if keepData {
		stopErr := runDockerCommand(ctx, stdout, stderr, "stop", instance.Container)
		fmt.Fprintf(stdout, "Kept stopped container %s and data volume %s\n", instance.Container, instance.Volume)
		return stopErr
	}
	removeErr := runDockerCommand(ctx, stdout, stderr, "rm", "-f", instance.Container)
	volumeErr := runDockerCommand(ctx, stdout, stderr, "volume", "rm", instance.Volume)
	return errors.Join(removeErr, volumeErr)
}

func runDockerCommand(ctx context.Context, stdout, stderr io.Writer, args ...string) error {
	command := exec.CommandContext(ctx, "docker", args...)
	command.Stdout, command.Stderr = stdout, stderr
	return command.Run()
}
