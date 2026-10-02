require "rails_helper"

RSpec.describe CredentialStore::Credential do
  let(:owner) { Factories.user }
  let(:repo) { Factories.repository(user: owner) }

  def build_credential(**attrs)
    described_class.new({
      name: "Production deploy token",
      description: "Used by deployment tools.",
      credential_type: "github/pat",
      scope_type: "repository",
      scope_id: repo.id,
      created_by: owner,
      owner_user: owner,
      payload: { "token" => "ghp_secret-token" }.to_json,
      safe_metadata: { "host" => "github.com", "username" => "deploy-bot", "fingerprint" => "SHA256:abc" },
      target_constraints: { "allowed_hosts" => [ "github.com" ], "allowed_url_prefixes" => [ "https://github.com/acme/" ] },
      allowed_surfaces: [ "workflow" ],
      allowed_tools: [ "git.push" ],
      last_rotated_at: 1.day.ago
    }.merge(attrs))
  end

  it "accepts a repository-scoped credential with safe metadata" do
    credential = build_credential

    expect(credential).to be_valid
  end

  it "round-trips payload through the encrypted text column" do
    credential = build_credential(payload: "secret-token")
    credential.save!

    reloaded = described_class.find(credential.id)

    expect(reloaded.payload).to eq("secret-token")
  end

  it "does not store plaintext payload material in the raw database column" do
    credential = build_credential(payload: "secret-token")
    credential.save!

    raw_value = ActiveRecord::Base.connection.select_value(
      "SELECT payload FROM credential_store_credentials WHERE id = #{credential.id}"
    )

    expect(raw_value.to_s).not_to include("secret-token")
  end

  it "requires credential type names to be lowercase policy identifiers" do
    credential = build_credential(credential_type: "GitHub PAT")

    expect(credential).not_to be_valid
    expect(credential.errors[:credential_type]).to be_present
  end

  it "validates user, repository, team, and instance scopes against existing owners" do
    team = Team.create!(name: "Deployers")

    expect(build_credential(scope_type: "user", scope_id: owner.id)).to be_valid
    expect(build_credential(scope_type: "repository", scope_id: repo.id)).to be_valid
    expect(build_credential(scope_type: "team", scope_id: team.id)).to be_valid
    expect(build_credential(scope_type: "instance", scope_id: nil)).to be_valid

    missing_repo = build_credential(scope_type: "repository", scope_id: 123_456)
    expect(missing_repo).not_to be_valid
    expect(missing_repo.errors[:scope_id]).to include("must reference an existing repository")
  end

  it "requires instance scope to have no scope_id" do
    credential = build_credential(scope_type: "instance", scope_id: repo.id)

    expect(credential).not_to be_valid
    expect(credential.errors[:scope_id]).to include("must be nil for instance scope")
  end

  it "rejects unsafe metadata keys and nested payload-like values" do
    credential = build_credential(safe_metadata: {
      "host" => "github.com",
      "token" => "secret",
      "context" => { "nested" => "value" }
    })

    expect(credential).not_to be_valid
    expect(credential.errors[:safe_metadata]).to include("contains unsupported keys: token")
    expect(credential.errors[:safe_metadata]).to include("must not include secret-bearing keys")
    expect(credential.errors[:safe_metadata]).to include("must contain only safe display values")
  end

  it "validates target constraints as constrained arrays" do
    credential = build_credential(target_constraints: {
      "allowed_hosts" => "github.com",
      "secret_hosts" => [ "example.com" ]
    })

    expect(credential).not_to be_valid
    expect(credential.errors[:target_constraints]).to include("contains unsupported keys: secret_hosts")
    expect(credential.errors[:target_constraints]).to include("allowed_hosts must be an array")
  end

  it "normalizes and validates allowed surfaces and tools" do
    credential = build_credential(
      allowed_surfaces: [ " workflow ", "workflow" ],
      allowed_tools: [ "git.push", "Bad Tool" ]
    )

    expect(credential).not_to be_valid
    expect(credential.allowed_surfaces).to eq([ "workflow" ])
    expect(credential.errors[:allowed_tools]).to include("contain invalid names: Bad Tool")
  end

  it "tracks revocation and active status without deleting the credential" do
    credential = build_credential(revoked_at: Time.current)

    expect(credential).to be_revoked
    expect(credential).not_to be_active
  end

  it "rejects a revocation timestamp before the last rotation" do
    credential = build_credential(
      last_rotated_at: Time.zone.parse("2026-10-02 10:00"),
      revoked_at: Time.zone.parse("2026-10-02 09:00")
    )

    expect(credential).not_to be_valid
    expect(credential.errors[:revoked_at]).to include("cannot be before last_rotated_at")
  end
end
