package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	"github.com/tkadauke/syrus/plugins/whisper_stt/container/internal/gateway"
)

const shutdownTimeout = 10 * time.Second

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		client := http.Client{Timeout: 3 * time.Second}
		response, err := client.Get("http://127.0.0.1:" + gateway.Port() + "/health")
		if err != nil || response.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		_ = response.Body.Close()
		return
	}
	if err := run(); err != nil {
		log.Fatalf("whisper gateway: %v", err)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	child := exec.Command("/usr/local/bin/whisper-server", "--host", "127.0.0.1", "--port", "8081",
		"--model", "/opt/whisper/models/ggml-base.en.bin", "--convert", "--tmp-dir", "/tmp/whisper-stt")
	child.Stdout, child.Stderr = os.Stdout, os.Stderr
	if err := child.Start(); err != nil {
		return err
	}
	childDone := make(chan error, 1)
	go func() { childDone <- child.Wait() }()

	service := gateway.NewService(gateway.ConfigFromEnvironment())
	server := &http.Server{
		Addr:              ":" + gateway.Port(),
		Handler:           service,
		ReadHeaderTimeout: 10 * time.Second,
		BaseContext: func(net.Listener) context.Context {
			return ctx
		},
	}
	serverDone := make(chan error, 1)
	go func() { serverDone <- server.ListenAndServe() }()

	var runErr error
	childExited := false
	select {
	case <-ctx.Done():
	case err := <-childDone:
		childExited = true
		if err == nil {
			runErr = errors.New("whisper-server exited unexpectedly")
		} else {
			runErr = errors.New("whisper-server exited: " + err.Error())
		}
	case err := <-serverDone:
		if !errors.Is(err, http.ErrServerClosed) {
			runErr = err
		}
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	_ = server.Shutdown(shutdownCtx)
	service.Close()
	if child.Process != nil && !childExited {
		_ = child.Process.Signal(syscall.SIGTERM)
		select {
		case <-childDone:
		case <-shutdownCtx.Done():
			_ = child.Process.Kill()
			<-childDone
		}
	}
	return runErr
}
