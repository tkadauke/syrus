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
    it "limits interactive and background coworkers to the connection selected by their mysql.read grant" do
      [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ].each_with_index do |role, index|
        granted = scoped_connection(scope_type: "user", scope_id: owner.id)
        outside_scope = scoped_connection(scope_type: "user", scope_id: owner.id)
        coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya #{index}", handle: "maya-db-#{index}",
          workspace_repo: "https://github.com/example/workspace.git")
        coworker_context = McpToolContext.new(surface: role == AgentRole::COWORKER_CHAT ? :chat : :run, role: role, user: owner,
          granted_capabilities: [ "mysql.read" ], capability_scopes: { "mysql.read" => granted.id }, agent_actor: coworker)

        expect(described_class.safe_connection_metadata(context: coworker_context).pluck(:id)).to eq([ granted.id ])
        expect(described_class.connection!(granted.id, context: coworker_context)).to eq(granted)
        expect {
          described_class.connection!(outside_scope.id, context: coworker_context, tool_name: "mysql_db_browser_list_tables")
        }.to raise_error(described_class::ConnectionNotFound)
        expect(MysqlQueryAudit.last).to have_attributes(
          mysql_connection: granted, user: owner, agent_actor: coworker, read_only: true, success: false,
          statement: "/* MCP tool call: mysql_db_browser_list_tables */",
          error_message: "Rejected: MySQL connection was not found or is outside the coworker grant scope."
        )
      end
    end

    it "never exposes legacy in-record credentials to a coworker" do
      connection = Factories.mysql_connection(agentic_access_enabled: true, password: "legacy-secret")
      coworker_context = McpToolContext.new(surface: :chat, role: AgentRole::COWORKER_CHAT, user: owner,
        granted_capabilities: [ "mysql.read" ], capability_scopes: { "mysql.read" => connection.id })

      expect(described_class.safe_connection_metadata(context: coworker_context)).to be_empty
      expect { described_class.connection!(connection.id, context: coworker_context) }.to raise_error(described_class::ConnectionNotFound)
    end

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
