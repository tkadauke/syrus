package cmd

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
	"github.com/tkadauke/syrus/cli/pkg/plugintrust"
)

func newPluginKeygenCommand() *cobra.Command {
	var output string
	command := &cobra.Command{Use: "keygen", Short: "Generate a local Ed25519 publisher key", Args: cobra.NoArgs, RunE: func(command *cobra.Command, _ []string) error {
		key, err := plugintrust.GenerateKey()
		if err != nil {
			return err
		}
		if output == "" {
			output = "syrus-plugin-publisher-key.json"
		}
		bytes, _ := json.MarshalIndent(key, "", "  ")
		file, err := os.OpenFile(output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return fmt.Errorf("refusing to overwrite publisher key: %w", err)
		}
		if _, err := file.Write(append(bytes, '\n')); err != nil {
			file.Close()
			return err
		}
		if err := file.Close(); err != nil {
			return err
		}
		fmt.Fprintf(command.OutOrStdout(), "%s\nFingerprint: %s\nKeep this private key offline and never commit or upload it.\n", output, key.Fingerprint)
		return nil
	}}
	command.Flags().StringVarP(&output, "output", "o", "", "private key output path")
	return command
}

func newPluginSignCommand() *cobra.Command {
	var keyPath, output string
	command := &cobra.Command{Use: "sign PACKAGE", Short: "Create a detached Ed25519 package signature", Args: cobra.ExactArgs(1), RunE: func(command *cobra.Command, args []string) error {
		if keyPath == "" {
			return fmt.Errorf("--key is required")
		}
		keyBytes, err := os.ReadFile(keyPath)
		if err != nil {
			return err
		}
		var key plugintrust.KeyFile
		if err := json.Unmarshal(keyBytes, &key); err != nil {
			return err
		}
		signature, err := plugintrust.Sign(args[0], key)
		if err != nil {
			return err
		}
		if output == "" {
			output = args[0] + ".sig"
		}
		bytes, _ := json.MarshalIndent(signature, "", "  ")
		if err := os.WriteFile(output, append(bytes, '\n'), 0644); err != nil {
			return err
		}
		fmt.Fprintln(command.OutOrStdout(), filepath.Clean(output))
		return nil
	}}
	command.Flags().StringVar(&keyPath, "key", "", "publisher private key file")
	command.Flags().StringVarP(&output, "output", "o", "", "signature output path")
	return command
}

func newPluginVerifyCommand() *cobra.Command {
	var signaturePath, trustStorePath string
	var local bool
	command := &cobra.Command{Use: "verify PACKAGE", Short: "Verify package provenance and print its trust label", Args: cobra.ExactArgs(1), RunE: func(command *cobra.Command, args []string) error {
		var signature plugintrust.Signature
		if signaturePath != "" {
			bytes, err := os.ReadFile(signaturePath)
			if err != nil {
				return err
			}
			if err := json.Unmarshal(bytes, &signature); err != nil {
				return err
			}
		}
		var store plugintrust.TrustStore
		if trustStorePath != "" {
			bytes, err := os.ReadFile(trustStorePath)
			if err != nil {
				return err
			}
			if err := json.Unmarshal(bytes, &store); err != nil {
				return err
			}
		}
		name, version, err := packageIdentity(args[0])
		if err != nil {
			return err
		}
		result, err := plugintrust.VerifyRelease(args[0], signature, store, local, name, version)
		if err != nil {
			return err
		}
		fmt.Fprintln(command.OutOrStdout(), result.TrustLabel)
		return nil
	}}
	command.Flags().StringVar(&signaturePath, "signature", "", "detached signature path")
	command.Flags().StringVar(&trustStorePath, "trust-store", "", "registry trust store path")
	command.Flags().BoolVar(&local, "local", false, "accept an unsigned local package")
	return command
}

func packageIdentity(path string) (string, string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", "", err
	}
	defer file.Close()
	gzipReader, err := gzip.NewReader(file)
	if err != nil {
		return "", "", err
	}
	defer gzipReader.Close()
	tars := tar.NewReader(gzipReader)
	for {
		header, err := tars.Next()
		if err != nil {
			return "", "", err
		}
		if header.Name != "package.json" {
			continue
		}
		var manifest struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		}
		if err := json.NewDecoder(tars).Decode(&manifest); err != nil {
			return "", "", err
		}
		return manifest.Name, manifest.Version, nil
	}
}
