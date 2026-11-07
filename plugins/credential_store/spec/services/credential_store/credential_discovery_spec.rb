require "rails_helper"

RSpec.describe CredentialStore::CredentialDiscovery do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:secret) { "never-return-this-secret-#{SecureRandom.hex(4)}" }

  def create_credential(name:, scope_type: "repository", scope_id: repository.id, **attrs)
    CredentialStore::Credential.create!({
      name: name,
      description: "Used by deployment automation",
      credential_type: "credential_store.url_token",
      scope_type: scope_type,
      scope_id: scope_id,
      created_by: user,
      owner_user: user,
      payload: secret,
      safe_metadata: { "host" => "api.example.com", "username" => "deploy" },
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example.com/" ] },
      allowed_surfaces: [],
      allowed_tools: [ "deploy.push" ],
      last_rotated_at: 1.hour.ago
    }.merge(attrs))
  end

  def names(payload)
    payload.fetch(:credentials).map { |credential| credential.fetch(:name) }
  end

  it "discovers user, attached repository, team, and instance scopes in chat" do
    attached_repository = Factories.repository(user: user)
    unattached_repository = Factories.repository(user: user)
    chat = ChatSession.create!(user: user, repository: repository)
    chat.chat_attachments.create!(attachable: attached_repository)
    team = Team.create!(name: "Platform")
    team.team_memberships.create!(user: user, role: "member")

    create_credential(name: "personal", scope_type: "user", scope_id: user.id)
    create_credential(name: "primary-repo")
    create_credential(name: "attached-repo", scope_id: attached_repository.id)
    create_credential(name: "unattached-repo", scope_id: unattached_repository.id)
    create_credential(name: "team", scope_type: "team", scope_id: team.id)
    create_credential(name: "instance", scope_type: "instance", scope_id: nil)
    other_user = Factories.user
    create_credential(name: "other-personal", scope_type: "user", scope_id: other_user.id, owner_user: other_user)

    payload = described_class.call(context: McpToolContext.from_chat_session(chat))

    expect(names(payload)).to eq(%w[attached-repo instance personal primary-repo team])
    expect(payload.fetch(:credentials).find { |row| row[:name] == "attached-repo" })
      .to include(scope: "repository", scope_label: attached_repository.slug, reference: a_string_matching(/\A\d+\z/))
  end

  it "limits workflow discovery to its repository while retaining team and instance visibility" do
    other_repository = Factories.repository(user: user)
    team = Team.create!(name: "Operations")
    team.team_memberships.create!(user: user, role: "member")
    create_credential(name: "workflow-repo", allowed_surfaces: [ "workflow" ])
    create_credential(name: "chat-only", allowed_surfaces: [ "chat" ])
    create_credential(name: "other-repo", scope_id: other_repository.id)
    create_credential(name: "team", scope_type: "team", scope_id: team.id)
    create_credential(name: "instance", scope_type: "instance", scope_id: nil)
    run = Factories.job_with_run(user: user, repository: repository).runs.first

    payload = described_class.call(context: McpToolContext.from_run(run))

    expect(names(payload)).to eq(%w[instance team workflow-repo])
  end

  it "excludes revoked and expired credentials and filters deterministically" do
    create_credential(name: "Zulu token", credential_type: "token")
    create_credential(name: "alpha token", credential_type: "token")
    create_credential(name: "Beta key", credential_type: "credential_store.ssh_key")
    create_credential(name: "revoked token", credential_type: "token", revoked_at: Time.current)
    create_credential(name: "expired token", credential_type: "token", expires_at: 1.minute.ago)
    run = Factories.job_with_run(user: user, repository: repository).runs.first

    payload = described_class.call(
      context: McpToolContext.from_run(run), credential_type: "token", scope: "repository", query: "token", limit: 1
    )

    expect(names(payload)).to eq([ "alpha token" ])
    expect(payload).to include(count: 1, limit: 1)
  end

  it "returns explicit empty guidance without creating an access event" do
    run = Factories.job_with_run(user: user, repository: repository).runs.first

    payload = described_class.call(context: McpToolContext.from_run(run), query: "missing")

    expect(payload).to include(credentials: [], count: 0)
    expect(payload.fetch(:guidance)).to include("Open Credential Store")
    expect(CredentialStore::CredentialAccessEvent.count).to eq(0)
  end

  it "batches scope authorization queries as credential volume grows" do
    team = Team.create!(name: "Release Engineering")
    team.team_memberships.create!(user: user, role: "member")
    run = Factories.job_with_run(user: user, repository: repository).runs.first
    context = McpToolContext.from_run(run)

    query_count = lambda do
      queries = []
      subscriber = lambda do |_name, _started, _finished, _id, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        described_class.call(context: context, limit: described_class::MAX_LIMIT)
      end
      queries.size
    end

    create_credential(name: "repository credential 0")
    create_credential(name: "team credential 0", scope_type: "team", scope_id: team.id)
    baseline = query_count.call

    4.times do |index|
      create_credential(name: "repository credential #{index + 1}")
      create_credential(name: "team credential #{index + 1}", scope_type: "team", scope_id: team.id)
    end

    expect(query_count.call).to eq(baseline)
  end

  it "pages past surface-ineligible credentials without loading an unbounded relation" do
    50.times do |index|
      create_credential(name: "a chat credential #{index}", allowed_surfaces: [ "chat" ])
    end
    create_credential(name: "z workflow credential", allowed_surfaces: [ "workflow" ])
    run = Factories.job_with_run(user: user, repository: repository).runs.first

    payload = described_class.call(context: McpToolContext.from_run(run), limit: 1)

    expect(names(payload)).to eq([ "z workflow credential" ])
  end

  it "never selects or returns encrypted payload material in success or error text" do
    credential = create_credential(name: "production token")
    run = Factories.job_with_run(user: user, repository: repository).runs.first
    sql = []
    subscriber = ->(_name, _started, _finished, _id, payload) { sql << payload[:sql] if payload[:sql]&.include?("credential_store_credentials") }

    response = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      CredentialStore::ListCredentialsTool.call(server_context: { run: run })
    end
    error = CredentialStore::ListCredentialsTool.call(server_context: { run: run }, scope: secret)
    combined_text = [ response, error ].flat_map(&:content).map { |entry| entry[:text] }.join(" ")

    expect(combined_text).not_to include(secret)
    expect(combined_text).not_to match(/\"payload\"|encrypted_payload/i)
    discovery_select = sql.find { |statement| statement.match?(/SELECT.+FROM [`\"]?credential_store_credentials/i) }
    expect(discovery_select).to be_present
    expect(discovery_select).not_to match(/[`\"]payload[`\"]/i)
    expect(CredentialStore::CredentialAccessEvent.where(credential: credential)).to be_empty
  end
end
