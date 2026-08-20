require "rails_helper"

RSpec.describe TestIdentitySearchIndex do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:other_repo) { Factories.repository(user: other_user) }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  it "upserts a durable test identity and finds it by name, suite_name, or file_path" do
    identity = TestIdentity.create!(
      repository: repo,
      fingerprint: "login",
      name: "LoginService validates credentials",
      suite_name: "AuthSpec",
      file_path: "spec/services/login_service_spec.rb",
      last_status: "failed"
    )

    described_class.upsert(identity)

    expect(described_class.search("LoginService", user_id: user.id).first).to include(test_identity_id: identity.id)
    expect(described_class.search("AuthSpec", user_id: user.id).first).to include(test_identity_id: identity.id)
    expect(described_class.search("login_service_spec", user_id: user.id).first).to include(test_identity_id: identity.id)
  end

  it "scopes results to the requested user" do
    own = TestIdentity.create!(repository: repo, fingerprint: "own", name: "shared search term", suite_name: "Suite")
    other = TestIdentity.create!(repository: other_repo, fingerprint: "other", name: "shared search term", suite_name: "Suite")

    described_class.upsert(own)
    described_class.upsert(other)

    expect(described_class.search("shared", user_id: user.id).map { |row| row[:test_identity_id] }).to eq([ own.id ])
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS test_identity_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE test_identity_fts
      USING fts5(
        name,
        suite_name,
        file_path,
        test_identity_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        last_status UNINDEXED,
        last_seen_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
