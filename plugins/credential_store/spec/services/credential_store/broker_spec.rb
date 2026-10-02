require "rails_helper"

RSpec.describe CredentialStore::Broker do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_with_run(user: user, repository: repository) }
  let(:run) { job.runs.first }
  let(:context) { McpToolContext.from_run(run) }
  let(:secret) { "super-secret-token-123" }

  def create_credential(**attrs)
    CredentialStore::Credential.create!({
      name: "deploy-token",
      credential_type: "credential_store.url_token",
      scope_type: "repository",
      scope_id: repository.id,
      created_by: user,
      owner_user: user,
      payload: secret,
      safe_metadata: { "host" => "api.example.com", "username" => "deploy-bot" },
      target_constraints: { "allowed_hosts" => [ "api.example.com" ], "allowed_url_prefixes" => [ "https://api.example.com/" ] },
      allowed_surfaces: [ "workflow" ],
      allowed_tools: [ "deploy.push" ],
      last_rotated_at: 1.hour.ago
    }.merge(attrs))
  end

  it "leases a credential as a restrictive temporary file and removes it after use" do
    credential = create_credential
    observed_path = nil
    observed_mode = nil

    result = described_class.with_credential_file(
      context: context,
      credential: credential.id,
      type: "credential_store.url_token",
      purpose: "deploy",
      tool_name: "deploy.push",
      target: { host: "api.example.com", url: "https://api.example.com/releases" }
    ) do |path, metadata|
      observed_path = path
      observed_mode = File.stat(path).mode & 0o777

      {
        path_exists: File.exist?(path),
        payload: File.read(path),
        metadata: metadata
      }
    end

    expect(observed_mode).to eq(0o600)
    expect(File.exist?(observed_path)).to be(false)
    expect(result[:path_exists]).to be(true)
    expect(result[:payload]).to eq(CredentialStore::Redaction::REDACTION)
    expect(result[:metadata]).to include(
      credential_id: credential.id,
      credential_name: "deploy-token",
      credential_type: "credential_store.url_token",
      purpose: "deploy",
      tool_name: "deploy.push",
      safe_metadata: { "host" => "api.example.com", "username" => "deploy-bot" }
    )

    event = CredentialStore::CredentialAccessEvent.last
    expect(event).to have_attributes(
      credential: credential,
      user: user,
      repository: repository,
      job: job,
      workflow: run.workflow,
      run: run,
      surface: "workflow",
      tool_name: "deploy.push",
      action: "lease",
      purpose: "deploy",
      result: "allowed",
      denial_reason: nil
    )
    expect(event.attributes.values.compact.join(" ")).not_to include(secret)
  end

  it "leases a credential as an env hash and clears the local material after use" do
    credential = create_credential
    yielded_env = nil

    result = described_class.with_credential_env(
      context: context,
      credential: "deploy-token",
      type: "credential_store.url_token",
      env_key: "DEPLOY_TOKEN",
      purpose: "deploy",
      tool_name: "deploy.push",
      target: { host: "api.example.com", url: "https://api.example.com/releases" }
    ) do |env, _metadata|
      yielded_env = env
      { output: "used #{env.fetch('DEPLOY_TOKEN')}" }
    end

    expect(yielded_env).to eq({})
    expect(ENV["DEPLOY_TOKEN"]).to be_nil
    expect(result).to eq(output: "used #{CredentialStore::Redaction::REDACTION}")
    expect(CredentialStore::CredentialAccessEvent.where(credential: credential, result: "allowed").count).to eq(1)
  end

  it "denies inactive, mismatched, disallowed, and constrained credentials with audit rows but no payload material" do
    credential = create_credential(allowed_tools: [ "deploy.pull" ])

    expect {
      described_class.with_credential_env(
        context: context,
        credential: credential.id,
        type: "credential_store.url_token",
        env_key: "DEPLOY_TOKEN",
        purpose: "deploy",
        tool_name: "deploy.push",
        target: { host: "api.example.com", url: "https://api.example.com/releases" }
      ) { |env, _metadata| env }
    }.to raise_error(CredentialStore::Broker::Denied, /tool not allowed/)

    event = CredentialStore::CredentialAccessEvent.last
    expect(event).to have_attributes(result: "denied", denial_reason: "tool not allowed")
    expect(event.attributes.values.compact.join(" ")).not_to include(secret)
  end

  it "denies revoked credentials" do
    credential = create_credential(revoked_at: Time.current)

    expect_denied_lease(credential, "credential revoked")
  end

  it "denies expired credentials" do
    credential = create_credential(expires_at: 1.minute.ago)

    expect_denied_lease(credential, "credential expired")
  end

  it "denies unexpected credential types" do
    credential = create_credential

    expect_denied_lease(credential, "credential type mismatch", type: "credential_store.ssh_key")
  end

  it "denies target constraint mismatches" do
    credential = create_credential

    expect_denied_lease(
      credential,
      "host not allowed",
      target: { host: "evil.example.com", url: "https://api.example.com/releases" }
    )
  end

  it "denies credentials outside the current repository scope" do
    other_repository = Factories.repository(user: user)
    credential = create_credential(scope_id: other_repository.id)

    expect {
      described_class.with_credential_env(
        context: context,
        credential: credential.id,
        type: "credential_store.url_token",
        env_key: "DEPLOY_TOKEN",
        purpose: "deploy",
        tool_name: "deploy.push"
      ) { |env, _metadata| env }
    }.to raise_error(CredentialStore::Broker::NotFound)

    expect(CredentialStore::CredentialAccessEvent.where(credential: credential)).to be_empty
  end

  it "authorizes team-scoped credentials through team repository membership" do
    team = Team.create!(name: "Platform")
    team.team_memberships.create!(user: user, role: "member")
    team.team_repositories.create!(repository: repository, role: "read")
    credential = create_credential(scope_type: "team", scope_id: team.id)

    result = described_class.with_credential_env(
      context: context,
      credential: credential.id,
      type: "credential_store.url_token",
      env_key: "DEPLOY_TOKEN",
      purpose: "deploy",
      tool_name: "deploy.push",
      target: { host: "api.example.com", url: "https://api.example.com/releases" }
    ) { |env, _metadata| env.fetch("DEPLOY_TOKEN") }

    expect(result).to eq(CredentialStore::Redaction::REDACTION)
  end

  it "scrubs block exceptions before persistent MCP usage recording can summarize them" do
    credential = create_credential

    expect {
      McpToolUsageRecorder.record_dispatch(
        surface: "workflow",
        tool_name: "deploy.push",
        tool_input: {},
        sidecar_mode: "persistent",
        run: run
      ) do
        described_class.with_credential_env(
          context: context,
          credential: credential.id,
          type: "credential_store.url_token",
          env_key: "DEPLOY_TOKEN",
          purpose: "deploy",
          tool_name: "deploy.push",
          target: { host: "api.example.com", url: "https://api.example.com/releases" }
        ) { |_env, _metadata| raise "probe printed #{secret}" }
      end
    }.to raise_error(CredentialStore::Broker::ExecutionError, /credential redacted/)

    usage = McpToolUsage.order(:id).last
    expect(usage).to be_error
    expect(usage.error_message_summary).to include(CredentialStore::Redaction::REDACTION)
    expect(usage.error_message_summary).not_to include(secret)
  end

  it "keeps concurrent leases isolated without daemon-global mutable state" do
    first = create_credential(name: "first-token", payload: "first-secret-token")
    second = create_credential(name: "second-token", payload: "second-secret-token")
    barrier = Queue.new
    release = Queue.new
    results = Queue.new

    threads = [
      Thread.new do
        described_class.with_credential_env(
          context: context,
          credential: first.id,
          type: "credential_store.url_token",
          env_key: "TOKEN",
          purpose: "deploy",
          tool_name: "deploy.push",
          target: { host: "api.example.com", url: "https://api.example.com/releases" }
        ) do |env, metadata|
          barrier << true
          release.pop
          results << [ metadata.fetch(:credential_name), env.fetch("TOKEN") ]
        end
      end,
      Thread.new do
        described_class.with_credential_env(
          context: context,
          credential: second.id,
          type: "credential_store.url_token",
          env_key: "TOKEN",
          purpose: "deploy",
          tool_name: "deploy.push",
          target: { host: "api.example.com", url: "https://api.example.com/releases" }
        ) do |env, metadata|
          barrier << true
          release.pop
          results << [ metadata.fetch(:credential_name), env.fetch("TOKEN") ]
        end
      end
    ]

    2.times { barrier.pop }
    2.times { release << true }
    threads.each(&:join)

    expect(2.times.map { results.pop }).to contain_exactly(
      [ "first-token", "first-secret-token" ],
      [ "second-token", "second-secret-token" ]
    )
    expect(CredentialStore::CredentialAccessEvent.where(result: "allowed").count).to eq(2)
  end

  def expect_denied_lease(credential, reason, type: "credential_store.url_token", target: { host: "api.example.com", url: "https://api.example.com/releases" })
    expect {
      described_class.with_credential_env(
        context: context,
        credential: credential.id,
        type: type,
        env_key: "DEPLOY_TOKEN",
        purpose: "deploy",
        tool_name: "deploy.push",
        target: target
      ) { |env, _metadata| env }
    }.to raise_error(CredentialStore::Broker::Denied, /#{Regexp.escape(reason)}/)

    event = CredentialStore::CredentialAccessEvent.order(:id).last
    expect(event).to have_attributes(credential: credential, result: "denied", denial_reason: reason)
    expect(event.attributes.values.compact.join(" ")).not_to include(secret)
  end
end
