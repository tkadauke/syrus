require "rails_helper"

RSpec.describe CredentialStore::SshExec do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_with_run(user: user, repository: repository) }
  let(:run) { job.runs.first }
  let(:context) { McpToolContext.from_run(run) }
  let(:private_key) { "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret-key-material\n-----END OPENSSH PRIVATE KEY-----\n" }
  let(:runner) { double("ssh runner") }

  def create_credential(**attrs)
    CredentialStore::Credential.create!({
      name: "prod-ssh",
      credential_type: "ssh_private_key",
      scope_type: "repository",
      scope_id: repository.id,
      created_by: user,
      owner_user: user,
      payload: private_key,
      safe_metadata: {
        "host" => "app.example.com",
        "username" => "deploy",
        "known_host" => "app.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakePublicHostKey",
        "fingerprint" => "SHA256:host"
      },
      target_constraints: { "allowed_hosts" => [ "app.example.com" ] },
      allowed_surfaces: [ "workflow" ],
      allowed_tools: [ "credential_store_ssh_exec" ],
      last_rotated_at: 1.hour.ago
    }.merge(attrs))
  end

  around do |example|
    original = described_class.runner
    described_class.runner = runner
    example.run
  ensure
    described_class.runner = original
  end

  it "executes through a restrictive temporary key file and removes temporary files" do
    credential = create_credential
    observed_key_path = nil
    observed_known_hosts_path = nil

    allow(runner).to receive(:call) do |env:, argv:|
      observed_key_path = argv[argv.index("-i") + 1]
      known_hosts_option = argv.find { |arg| arg.start_with?("UserKnownHostsFile=") }
      observed_known_hosts_path = known_hosts_option.split("=", 2).last

      expect(env).to eq({})
      expect(File.stat(observed_key_path).mode & 0o777).to eq(0o600)
      expect(File.read(observed_key_path)).to eq(private_key)
      expect(File.stat(observed_known_hosts_path).mode & 0o777).to eq(0o600)
      expect(File.read(observed_known_hosts_path)).to include("app.example.com ssh-ed25519")
      expect(argv).to include("deploy@app.example.com", "uptime")

      CredentialStore::SshRunner::Result.new(stdout: "up\n", stderr: "", status: 0)
    end

    result = described_class.call(
      context: context,
      credential: credential.id,
      host: "app.example.com",
      user: "deploy",
      command: "uptime"
    )

    expect(result).to include(ok: true, status: 0, known_hosts_enforced: true, fingerprint: "SHA256:host")
    expect(result[:stdout]).to include(text: "up\n", truncated: false)
    expect(result[:credential]).to include(credential_id: credential.id, credential_type: "ssh_private_key")
    expect(File.exist?(observed_key_path)).to be(false)
    expect(File.exist?(observed_known_hosts_path)).to be(false)

    expect(CredentialStore::CredentialAccessEvent.last).to have_attributes(
      credential: credential,
      user: user,
      repository: repository,
      run: run,
      tool_name: "credential_store_ssh_exec",
      action: "lease",
      result: "allowed"
    )
  end

  it "supports JSON payloads with a private key and passphrase without exposing either" do
    passphrase = "correct horse battery staple"
    credential = create_credential(payload: { private_key: private_key, passphrase: passphrase }.to_json)

    allow(runner).to receive(:call) do |env:, argv:|
      expect(env).to include(
        "SSH_ASKPASS_REQUIRE" => "force",
        "SYRUS_CREDENTIAL_STORE_SSH_PASSPHRASE" => passphrase
      )
      expect(argv).to include("-o", "BatchMode=no")

      CredentialStore::SshRunner::Result.new(stdout: private_key, stderr: passphrase, status: 1)
    end

    result = described_class.call(
      context: context,
      credential: credential.id,
      host: "app.example.com",
      user: "deploy",
      command: "uptime"
    )

    serialized = result.inspect
    expect(serialized).to include(CredentialStore::Redaction::REDACTION)
    expect(serialized).not_to include("secret-key-material")
    expect(serialized).not_to include(passphrase)
  end

  it "denies revoked credentials and records the denial" do
    credential = create_credential(revoked_at: Time.current)
    allow(runner).to receive(:call)

    expect {
      described_class.call(context: context, credential: credential.id, host: "app.example.com", user: "deploy", command: "uptime")
    }.to raise_error(CredentialStore::Broker::Denied, /credential revoked/)
    expect(runner).not_to have_received(:call)
    expect(CredentialStore::CredentialAccessEvent.last).to have_attributes(
      credential: credential,
      result: "denied",
      denial_reason: "credential revoked"
    )
  end

  it "denies host constraint mismatches before invoking the runner" do
    credential = create_credential
    allow(runner).to receive(:call)

    expect {
      described_class.call(context: context, credential: credential.id, host: "other.example.com", user: "deploy", command: "uptime")
    }.to raise_error(CredentialStore::Broker::Denied, /host not allowed/)
    expect(runner).not_to have_received(:call)
    expect(CredentialStore::CredentialAccessEvent.last).to have_attributes(
      result: "denied",
      denial_reason: "host not allowed"
    )
  end

  it "rejects safe metadata host mismatches before invoking the runner" do
    credential = create_credential(
      safe_metadata: { "host" => "other.example.com", "username" => "deploy" },
      target_constraints: { "allowed_hosts" => [ "app.example.com" ] }
    )
    allow(runner).to receive(:call)

    expect {
      described_class.call(context: context, credential: credential.id, host: "app.example.com", user: "deploy", command: "uptime")
    }.to raise_error(CredentialStore::Broker::ExecutionError, /credential host metadata does not match target/)
    expect(runner).not_to have_received(:call)
  end

  it "refuses unconstrained credentials unless explicitly allowed" do
    credential = create_credential(safe_metadata: { "username" => "deploy" }, target_constraints: {})

    expect {
      described_class.call(context: context, credential: credential.id, host: "app.example.com", user: "deploy", command: "uptime")
    }.to raise_error(CredentialStore::Broker::ExecutionError, /no host or known-host constraint/)

    allow(runner).to receive(:call).and_return(CredentialStore::SshRunner::Result.new(stdout: "", stderr: "", status: 0))

    result = described_class.call(
      context: context,
      credential: credential.id,
      host: "app.example.com",
      user: "deploy",
      command: "uptime",
      allow_unconstrained_host: true
    )

    expect(result[:ok]).to be(true)
  end

  it "does not treat fingerprint-only metadata as host enforcement" do
    credential = create_credential(safe_metadata: { "username" => "deploy", "fingerprint" => "SHA256:host" }, target_constraints: {})

    expect {
      described_class.call(context: context, credential: credential.id, host: "app.example.com", user: "deploy", command: "uptime")
    }.to raise_error(CredentialStore::Broker::ExecutionError, /no host or known-host constraint/)
  end

  it "refuses risky command patterns unless explicitly allowed" do
    credential = create_credential

    expect {
      described_class.call(context: context, credential: credential.id, host: "app.example.com", user: "deploy", command: "rm -rf /tmp/app")
    }.to raise_error(CredentialStore::SshExec::RiskyCommand, /requires explicit/)

    allow(runner).to receive(:call).and_return(CredentialStore::SshRunner::Result.new(stdout: "", stderr: "", status: 0))

    result = described_class.call(
      context: context,
      credential: credential.id,
      host: "app.example.com",
      user: "deploy",
      command: "rm -rf /tmp/app",
      allow_risky_command: true
    )

    expect(result[:ok]).to be(true)
  end

  it "redacts stdout and stderr returned by the runner" do
    credential = create_credential
    allow(runner).to receive(:call).and_return(
      CredentialStore::SshRunner::Result.new(stdout: "stdout #{private_key}", stderr: "stderr #{private_key}", status: 2)
    )

    result = described_class.call(
      context: context,
      credential: credential.id,
      host: "app.example.com",
      user: "deploy",
      command: "uptime"
    )

    expect(result[:ok]).to be(false)
    expect(result[:stdout][:text]).to include(CredentialStore::Redaction::REDACTION)
    expect(result[:stderr][:text]).to include(CredentialStore::Redaction::REDACTION)
    expect(result.inspect).not_to include("secret-key-material")
  end
end
