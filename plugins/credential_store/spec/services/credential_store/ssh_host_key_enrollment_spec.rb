require "rails_helper"

RSpec.describe CredentialStore::SshHostKeyEnrollment do
  let(:key_data) { Base64.strict_encode64("test-host-public-key") }
  let(:result) { CredentialStore::SshRunner::Result.new(stdout: "example.test ssh-ed25519 #{key_data}\n", stderr: "", status: 0) }

  after { described_class.runner = nil }

  it "probes with bounded, option-safe arguments and derives the SHA-256 fingerprint" do
    runner = class_double(CredentialStore::SshRunner)
    described_class.runner = runner
    expect(runner).to receive(:call).with(env: {}, argv: [ "ssh-keyscan", "-T", "5", "-p", "22", "--", "example.test" ], timeout: 10).and_return(result)

    key = described_class.probe!(host: "example.test", port: 22)

    expect(key.as_json).to include(host: "example.test", port: 22, key_type: "ssh-ed25519", known_host: "example.test ssh-ed25519 #{key_data}")
    expect(key.fingerprint).to start_with("SHA256:")
  end

  it "rejects option injection, invalid ports, mismatched manual lines, and timeouts" do
    expect { described_class.probe!(host: "-oProxyCommand=bad", port: 22) }.to raise_error(CredentialStore::SshExec::InvalidTarget)
    expect { described_class.manual!(host: "example.test", port: 0, known_host: "example.test ssh-ed25519 #{key_data}") }.to raise_error(CredentialStore::SshExec::InvalidTarget)
    expect { described_class.manual!(host: "example.test", port: 22, known_host: "other.test ssh-ed25519 #{key_data}") }.to raise_error(CredentialStore::SshExec::InvalidTarget, /does not match/)

    described_class.runner = class_double(CredentialStore::SshRunner, call: CredentialStore::SshRunner::Result.new(stdout: "", stderr: "", status: 124))
    expect { described_class.probe!(host: "example.test", port: 22) }.to raise_error(described_class::ProbeTimedOut)
  end

  it "requires bracketed host notation for a nonstandard port" do
    key = described_class.manual!(host: "example.test", port: 2222, known_host: "[example.test]:2222 ssh-ed25519 #{key_data}")
    expect(key.port).to eq(2222)
  end
end
