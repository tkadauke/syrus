require "rails_helper"

RSpec.describe CredentialStore::SshKeyMaterial do
  let(:private_key) do
    "-----BEGIN OPENSSH PRIVATE KEY-----\nline one  \nline two\n-----END OPENSSH PRIVATE KEY-----"
  end

  it "normalizes raw private keys to exactly one trailing newline" do
    expect(described_class.from_payload(private_key).private_key).to eq("#{private_key}\n")
    expect(described_class.from_payload("#{private_key}\n\n").private_key).to eq("#{private_key}\n")
  end

  it "normalizes only private-key material in JSON payloads" do
    passphrase = " passphrase with whitespace \n"
    material = described_class.from_payload({ private_key: "#{private_key}\n\n", passphrase: passphrase }.to_json)

    expect(material.private_key).to eq("#{private_key}\n")
    expect(material.passphrase).to eq(passphrase)
  end

  it "rejects public-key-only and malformed PEM payloads without echoing them" do
    public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest operator@example.test"

    expect { described_class.from_payload(public_key) }
      .to raise_error(CredentialStore::SshExec::InvalidTarget, "SSH credential payload must contain a private key, not a public key")
    expect { described_class.from_payload("-----BEGIN OPENSSH PRIVATE KEY-----\ntruncated") }
      .to raise_error(CredentialStore::SshExec::InvalidTarget, "SSH credential payload contains a malformed private key")
  end
end
