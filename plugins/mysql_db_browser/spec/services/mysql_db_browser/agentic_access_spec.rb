require "rails_helper"

RSpec.describe MysqlDbBrowser::AgenticAccess do
  let(:owner) { Factories.user }
  let(:member) { Factories.user }
  let(:outsider) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  def context(user:, surface: :chat, allowed_repository_ids: [])
    McpToolContext.new(surface: surface, role: nil, user: user, allowed_repository_ids: allowed_repository_ids)
  end

  def scoped_connection(scope_type:, scope_id:, user: owner)
    connection = Factories.mysql_connection(agentic_access_enabled: true)
    MysqlDbBrowser::CredentialMaterial.store!(connection, "secret", user: user, scope_type: scope_type, scope_id: scope_id)
    connection.reload
  end

  describe ".connection!" do
    it "returns the connection when agentic access is enabled" do
      connection = scoped_connection(scope_type: "user", scope_id: owner.id)

      expect(described_class.connection!(connection.id, context: context(user: owner))).to eq(connection)
      expect(described_class.connection!(connection.id, context: context(user: owner, surface: :run))).to eq(connection)
    end

    it "raises AccessDisabled when the connection has not opted in" do
      connection = Factories.mysql_connection(agentic_access_enabled: false)
      MysqlDbBrowser::CredentialMaterial.store!(connection, "secret", user: owner, scope_type: "user", scope_id: owner.id)

      expect { described_class.connection!(connection.id, context: context(user: owner)) }.to raise_error(described_class::AccessDisabled, /Agentic access is disabled/)
    end

    it "raises ConnectionNotFound for an unknown id" do
      expect { described_class.connection!(-1, context: context(user: owner)) }.to raise_error(described_class::ConnectionNotFound)
    end

    it "makes user-scoped and legacy connections nonexistent to other users" do
      user_connection = scoped_connection(scope_type: "user", scope_id: owner.id)
      legacy_connection = Factories.mysql_connection(agentic_access_enabled: true, password: "legacy")

      [ user_connection, legacy_connection ].each do |connection|
        expect {
          described_class.connection!(connection.id, context: context(user: outsider))
        }.to raise_error(described_class::ConnectionNotFound)
      end
    end

    it "authorizes repository scopes through direct membership and a team grant, while enforcing allowed repositories" do
      direct_member = Factories.user
      team_member = Factories.user
      RepositoryMembership.create!(repository: repository, user: direct_member, role: "read")
      team = Team.create!(name: "Database readers")
      team.team_memberships.create!(user: team_member, role: "member")
      team.team_repositories.create!(repository: repository, role: "read")
      connection = scoped_connection(scope_type: "repository", scope_id: repository.id)

      [ direct_member, team_member ].each do |user|
        expect(described_class.connection!(connection.id, context: context(user: user, surface: :run, allowed_repository_ids: [ repository.id ]))).to eq(connection)
        expect {
          described_class.connection!(connection.id, context: context(user: user, allowed_repository_ids: []))
        }.to raise_error(described_class::ConnectionNotFound)
      end
    end

    it "authorizes team members, any signed-in user for instance scope, and admins for every scope" do
      team = Team.create!(name: "Database operators")
      team.team_memberships.create!(user: member, role: "member")
      team_connection = scoped_connection(scope_type: "team", scope_id: team.id)
      instance_connection = scoped_connection(scope_type: "instance", scope_id: nil)
      admin = Factories.user(admin: true)

      expect(described_class.connection!(team_connection.id, context: context(user: member))).to eq(team_connection)
      expect(described_class.connection!(instance_connection.id, context: context(user: outsider))).to eq(instance_connection)
      expect(described_class.connection!(team_connection.id, context: context(user: admin))).to eq(team_connection)
      expect(described_class.connection!(Factories.mysql_connection(agentic_access_enabled: true, password: "legacy").id, context: context(user: admin))).to be_present
    end
  end

  describe ".connection_with_write_access!" do
    it "returns the connection when it has opted into writes" do
      connection = Factories.mysql_connection(allow_writes: true)

      expect(described_class.connection_with_write_access!(connection)).to eq(connection)
    end

    it "raises WriteAccessDisabled when the connection has not opted into writes" do
      connection = Factories.mysql_connection(allow_writes: false)

      expect {
        described_class.connection_with_write_access!(connection)
      }.to raise_error(described_class::WriteAccessDisabled, /Write access is disabled/)
    end

    it "does not re-check agentic_access_enabled, since the caller already resolved the connection" do
      connection = Factories.mysql_connection(agentic_access_enabled: false, allow_writes: true)

      expect(described_class.connection_with_write_access!(connection)).to eq(connection)
    end
  end
end
