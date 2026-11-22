package plugintrust

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
)

type KeyFile struct {
	Algorithm   string `json:"algorithm"`
	PrivateKey  string `json:"private_key"`
	PublicKey   string `json:"public_key"`
	Fingerprint string `json:"fingerprint"`
}

type Signature struct {
	Algorithm   string `json:"algorithm"`
	Digest      string `json:"digest"`
	PublicKey   string `json:"public_key"`
	Fingerprint string `json:"fingerprint"`
	Signature   string `json:"signature"`
}

type Publisher struct {
	Fingerprint string `json:"fingerprint"`
	Label       string `json:"label"`
	Prefix      string `json:"prefix"`
}

type RevokedRelease struct {
	Name, Version, Digest string
}

func (r *RevokedRelease) UnmarshalJSON(data []byte) error {
	var value struct{ Name, Version, Digest string }
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	r.Name, r.Version, r.Digest = value.Name, value.Version, value.Digest
	return nil
}

type TrustStore struct {
	Publishers      []Publisher      `json:"publishers"`
	RevokedKeys     []string         `json:"revoked_keys"`
	RevokedReleases []RevokedRelease `json:"revoked_releases"`
}

type Result struct {
	TrustLabel, Fingerprint string
}

func GenerateKey() (KeyFile, error) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return KeyFile{}, err
	}
	fingerprint := Fingerprint(publicKey)
	return KeyFile{"ed25519", base64.StdEncoding.EncodeToString(privateKey), base64.StdEncoding.EncodeToString(publicKey), fingerprint}, nil
}

func Fingerprint(publicKey []byte) string {
	sum := sha256.Sum256(publicKey)
	return hex.EncodeToString(sum[:])
}

func Sign(packagePath string, key KeyFile) (Signature, error) {
	contents, err := os.ReadFile(packagePath)
	if err != nil {
		return Signature{}, err
	}
	privateKey, err := base64.StdEncoding.DecodeString(key.PrivateKey)
	if err != nil {
		return Signature{}, err
	}
	publicKey, err := base64.StdEncoding.DecodeString(key.PublicKey)
	if err != nil {
		return Signature{}, err
	}
	if key.Algorithm != "ed25519" || len(privateKey) != ed25519.PrivateKeySize || len(publicKey) != ed25519.PublicKeySize {
		return Signature{}, errors.New("invalid Ed25519 publisher key")
	}
	derivedPublic := ed25519.PrivateKey(privateKey).Public().(ed25519.PublicKey)
	if !ed25519.PublicKey(publicKey).Equal(derivedPublic) || key.Fingerprint != Fingerprint(publicKey) {
		return Signature{}, errors.New("publisher key identity does not match its private key")
	}
	digestBytes := sha256.Sum256(contents)
	digest := hex.EncodeToString(digestBytes[:])
	return Signature{"ed25519", digest, key.PublicKey, Fingerprint(publicKey), base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, []byte(digest)))}, nil
}

func Verify(packagePath string, signature Signature, store TrustStore, local bool) (Result, error) {
	return VerifyRelease(packagePath, signature, store, local, "", "")
}

func VerifyRelease(packagePath string, signature Signature, store TrustStore, local bool, name, version string) (Result, error) {
	if signature.Signature == "" {
		if local {
			return Result{TrustLabel: "unsigned_local"}, nil
		}
		return Result{}, errors.New("unsigned packages are allowed only for local installation")
	}
	contents, err := os.ReadFile(packagePath)
	if err != nil {
		return Result{}, err
	}
	digestBytes := sha256.Sum256(contents)
	digest := hex.EncodeToString(digestBytes[:])
	if signature.Algorithm != "ed25519" || signature.Digest != digest {
		return Result{}, errors.New("signature digest does not match package")
	}
	for _, release := range store.RevokedReleases {
		if release.Name == name && release.Version == version && (release.Digest == "" || release.Digest == digest) {
			return Result{}, errors.New("plugin release has been revoked")
		}
	}
	publicKey, err := base64.StdEncoding.DecodeString(signature.PublicKey)
	if err != nil {
		return Result{}, fmt.Errorf("invalid public key: %w", err)
	}
	fingerprint := Fingerprint(publicKey)
	if fingerprint != signature.Fingerprint {
		return Result{}, errors.New("signature fingerprint does not match public key")
	}
	for _, revoked := range store.RevokedKeys {
		if revoked == fingerprint {
			return Result{}, errors.New("publisher key has been revoked")
		}
	}
	signed, err := base64.StdEncoding.DecodeString(signature.Signature)
	if err != nil || !ed25519.Verify(publicKey, []byte(digest), signed) {
		return Result{}, errors.New("signature verification failed")
	}
	for _, publisher := range store.Publishers {
		if publisher.Fingerprint == fingerprint {
			if publisher.Label != "official" && publisher.Label != "verified" && publisher.Label != "community" {
				return Result{}, errors.New("invalid publisher trust label")
			}
			return Result{publisher.Label, fingerprint}, nil
		}
	}
	return Result{}, errors.New("publisher key is not present in the trust store")
}
