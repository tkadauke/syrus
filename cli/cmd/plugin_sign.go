package cmd

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

type pluginSignature struct {
	Version     int    `json:"version"`
	Algorithm   string `json:"algorithm"`
	Fingerprint string `json:"fingerprint"`
	Digest      string `json:"digest"`
	Signature   string `json:"signature"`
}

type pluginTrustKey struct {
	Fingerprint string `json:"fingerprint"`
	Label       string `json:"label"`
	PublicKey   string `json:"public_key"`
}

type revokedPluginRelease struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	Digest  string `json:"digest,omitempty"`
}

type pluginTrustStore struct {
	Version         int                    `json:"version"`
	Keys            []pluginTrustKey       `json:"keys"`
	RevokedKeys     []string               `json:"revoked_keys"`
	RevokedReleases []revokedPluginRelease `json:"revoked_releases"`
}

type pluginVerification struct {
	Trusted     bool
	Label       string
	Fingerprint string
	Reason      string
}

type pluginDesiredManifest struct {
	Plugins []struct {
		Name       string `json:"name"`
		Version    string `json:"version"`
		TrustLabel string `json:"trust_label"`
	} `json:"plugins"`
}

func pluginKeyFingerprint(public ed25519.PublicKey) string {
	der, _ := x509.MarshalPKIXPublicKey(public)
	digest := sha256.Sum256(der)
	return "sha256:" + hex.EncodeToString(digest[:])
}

func signPluginPackage(packagePath, keyPath string) (pluginSignature, error) {
	contents, err := os.ReadFile(packagePath)
	if err != nil {
		return pluginSignature{}, err
	}
	block, _ := pem.Decode(mustReadFile(keyPath, &err))
	if err != nil {
		return pluginSignature{}, err
	}
	if block == nil {
		return pluginSignature{}, errors.New("private key is not PEM encoded")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return pluginSignature{}, err
	}
	key, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return pluginSignature{}, errors.New("private key is not Ed25519")
	}
	digest := sha256.Sum256(contents)
	public := key.Public().(ed25519.PublicKey)
	return pluginSignature{Version: 1, Algorithm: "ed25519", Fingerprint: pluginKeyFingerprint(public),
		Digest: "sha256:" + hex.EncodeToString(digest[:]), Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(key, digest[:]))}, nil
}

func mustReadFile(path string, err *error) []byte {
	contents, readErr := os.ReadFile(path)
	*err = readErr
	return contents
}

func verifyPluginPackage(packagePath string, envelope pluginSignature, store pluginTrustStore, name, version string) pluginVerification {
	result := pluginVerification{Fingerprint: envelope.Fingerprint}
	for _, fingerprint := range store.RevokedKeys {
		if fingerprint == envelope.Fingerprint {
			result.Reason = "revoked_key"
			return result
		}
	}
	contents, err := os.ReadFile(packagePath)
	if err != nil {
		result.Reason = "invalid_package"
		return result
	}
	digest := sha256.Sum256(contents)
	digestHex := hex.EncodeToString(digest[:])
	for _, release := range store.RevokedReleases {
		if release.Name == name && release.Version == version && (release.Digest == "" || release.Digest == digestHex) {
			result.Reason = "revoked_release"
			return result
		}
	}
	for _, trusted := range store.Keys {
		if trusted.Fingerprint != envelope.Fingerprint {
			continue
		}
		result.Label = trusted.Label
		publicDER, decodeErr := base64.StdEncoding.DecodeString(trusted.PublicKey)
		parsed, parseErr := x509.ParsePKIXPublicKey(publicDER)
		public, keyOK := parsed.(ed25519.PublicKey)
		signature, signatureErr := base64.StdEncoding.DecodeString(envelope.Signature)
		if decodeErr != nil || parseErr != nil || !keyOK || signatureErr != nil || pluginKeyFingerprint(public) != trusted.Fingerprint ||
			envelope.Version != 1 || envelope.Algorithm != "ed25519" || envelope.Digest != "sha256:"+digestHex ||
			!ed25519.Verify(public, digest[:], signature) {
			result.Reason = "invalid_signature"
			return result
		}
		if trusted.Label != "official" && trusted.Label != "verified" && trusted.Label != "community" {
			result.Reason = "invalid_trust_label"
			return result
		}
		result.Trusted = true
		return result
	}
	result.Reason = "unknown_key"
	return result
}

func newPluginKeygenCommand() *cobra.Command {
	var output string
	command := &cobra.Command{Use: "keygen", Short: "Generate an Ed25519 plugin publisher key", RunE: func(command *cobra.Command, _ []string) error {
		_, private, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return err
		}
		der, err := x509.MarshalPKCS8PrivateKey(private)
		if err != nil {
			return err
		}
		file, err := os.OpenFile(output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		if _, err := file.Write(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})); err != nil {
			file.Close()
			return err
		}
		if err := file.Close(); err != nil {
			return err
		}
		public := private.Public().(ed25519.PublicKey)
		publicDER, err := x509.MarshalPKIXPublicKey(public)
		if err != nil {
			return err
		}
		fmt.Fprintf(command.OutOrStdout(), "%s\nFingerprint: %s\nPublic key: %s\nKeep this private key local and never commit or upload it.\n",
			output, pluginKeyFingerprint(public), base64.StdEncoding.EncodeToString(publicDER))
		return nil
	}}
	command.Flags().StringVarP(&output, "output", "o", "syrus-plugin-publisher.pem", "private key output path")
	return command
}

func newPluginListCommand() *cobra.Command {
	var manifestPath, signaturePath, publicKey string
	command := &cobra.Command{Use: "list", Short: "List desired plugins and publisher trust", RunE: func(command *cobra.Command, _ []string) error {
		manifestBody, err := os.ReadFile(manifestPath)
		if err != nil {
			return err
		}
		signatureBody, err := os.ReadFile(signaturePath)
		if err != nil {
			return err
		}
		signature, err := base64.StdEncoding.DecodeString(string(bytes.TrimSpace(signatureBody)))
		if err != nil {
			return errors.New("desired-state signature is invalid")
		}
		public, err := base64.StdEncoding.DecodeString(publicKey)
		if err != nil || len(public) != ed25519.PublicKeySize || !ed25519.Verify(ed25519.PublicKey(public), manifestBody, signature) {
			return errors.New("desired-state signature verification failed")
		}
		var manifest pluginDesiredManifest
		if err := json.Unmarshal(manifestBody, &manifest); err != nil {
			return err
		}
		for _, plugin := range manifest.Plugins {
			label := plugin.TrustLabel
			if label == "" {
				label = "unsigned_local"
			}
			fmt.Fprintf(command.OutOrStdout(), "%s\t%s\t%s\n", plugin.Name, plugin.Version, label)
		}
		return nil
	}}
	command.Flags().StringVar(&manifestPath, "manifest", "", "signed desired-state manifest path")
	command.Flags().StringVar(&signaturePath, "signature", "", "detached desired-state signature path")
	command.Flags().StringVar(&publicKey, "public-key", "", "base64 desired-state public key")
	for _, flag := range []string{"manifest", "signature", "public-key"} {
		_ = command.MarkFlagRequired(flag)
	}
	return command
}

func newPluginSignCommand() *cobra.Command {
	var key, output string
	command := &cobra.Command{Use: "sign PACKAGE", Short: "Create a detached Ed25519 package signature", Args: cobra.ExactArgs(1), RunE: func(command *cobra.Command, args []string) error {
		envelope, err := signPluginPackage(args[0], key)
		if err != nil {
			return err
		}
		if output == "" {
			output = args[0] + ".sig"
		}
		data, _ := json.MarshalIndent(envelope, "", "  ")
		if err := os.WriteFile(output, append(data, '\n'), 0644); err != nil {
			return err
		}
		fmt.Fprintln(command.OutOrStdout(), output)
		return nil
	}}
	command.Flags().StringVar(&key, "key", "", "Ed25519 publisher private key")
	_ = command.MarkFlagRequired("key")
	command.Flags().StringVarP(&output, "output", "o", "", "signature output path")
	return command
}

func newPluginVerifyCommand() *cobra.Command {
	var signaturePath, trustStorePath, name, version string
	command := &cobra.Command{Use: "verify PACKAGE", Short: "Verify package provenance and revocation", Args: cobra.ExactArgs(1), RunE: func(command *cobra.Command, args []string) error {
		var envelope pluginSignature
		var store pluginTrustStore
		if err := readJSONFile(signaturePath, &envelope); err != nil {
			return err
		}
		if err := readJSONFile(trustStorePath, &store); err != nil {
			return err
		}
		result := verifyPluginPackage(args[0], envelope, store, name, version)
		if !result.Trusted {
			return fmt.Errorf("package is not trusted: %s", result.Reason)
		}
		fmt.Fprintf(command.OutOrStdout(), "%s\t%s\n", result.Label, result.Fingerprint)
		return nil
	}}
	command.Flags().StringVar(&signaturePath, "signature", "", "detached signature path")
	command.Flags().StringVar(&trustStorePath, "trust-store", "", "registry trust store path")
	command.Flags().StringVar(&name, "name", "", "registry plugin name")
	command.Flags().StringVar(&version, "version", "", "registry plugin version")
	for _, flag := range []string{"signature", "trust-store", "name", "version"} {
		_ = command.MarkFlagRequired(flag)
	}
	return command
}

func readJSONFile(path string, target any) error {
	contents, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(contents, target)
}
