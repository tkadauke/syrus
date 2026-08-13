require "rails_helper"

RSpec.describe "Mcp::Tools epic dependency tools" do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        Mcp::Tools::AddEpicDependencyTool,
        Mcp::Tools::RemoveEpicDependencyTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  def error_text(response)
    response.dig(:result, :content, 0, :text)
  end

  describe "add_epic_dependency" do
    it "creates an EpicDependency and returns the updated dependency ids" do
      epic = Factories.epic(user: user, repository: repository)
      prerequisite = Factories.epic(user: user, repository: repository)

      response = call_tool("add_epic_dependency", epic_id: epic.id, depends_on_epic_id: prerequisite.id)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload(response)).to include(epic_id: epic.id, depends_on: [ prerequisite.id ])
      expect(epic.reload.depends_on_epics).to contain_exactly(prerequisite)
    end

    it "rejects dependencies that would create a cycle" do
      root = Factories.epic(user: user, repository: repository)
      leaf = Factories.epic(user: user, repository: repository)
      EpicDependency.create!(epic: leaf, depends_on_epic: root, derived: false)

      response = call_tool("add_epic_dependency", epic_id: root.id, depends_on_epic_id: leaf.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to match(/cycle/)
      expect(root.reload.depends_on_epics).to be_empty
    end

    it "rejects cross-user Epics" do
      epic = Factories.epic(user: user, repository: repository)
      other_user = Factories.user
      other_epic = Factories.epic(user: other_user, repository: Factories.repository(user: other_user))

      response = call_tool("add_epic_dependency", epic_id: epic.id, depends_on_epic_id: other_epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("epic not found in this repository")
      expect(epic.reload.depends_on_epics).to be_empty
    end

    it "allows an admin to link Epics across repositories/users" do
      admin = Factories.user(admin: true)
      other_user = Factories.user
      epic = Factories.epic(user: other_user, repository: Factories.repository(user: other_user))
      prerequisite = Factories.epic(user: other_user, repository: Factories.repository(user: other_user))
      admin_session = ChatSession.create!(user: admin)
      admin_server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ Mcp::Tools::AddEpicDependencyTool ],
        server_context: { chat_session: admin_session }
      )

      raw = admin_server.handle_json({
        jsonrpc: "2.0", id: 1, method: "tools/call",
        params: { name: "add_epic_dependency", arguments: { epic_id: epic.id, depends_on_epic_id: prerequisite.id } }
      }.to_json)
      response = JSON.parse(raw, symbolize_names: true)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(epic.reload.depends_on_epics).to contain_exactly(prerequisite)
    end
  end

  describe "remove_epic_dependency" do
    it "destroys an existing EpicDependency" do
      epic = Factories.epic(user: user, repository: repository)
      prerequisite = Factories.epic(user: user, repository: repository)
      EpicDependency.create!(epic: epic, depends_on_epic: prerequisite, derived: false)

      response = call_tool("remove_epic_dependency", epic_id: epic.id, depends_on_epic_id: prerequisite.id)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload(response)).to include(epic_id: epic.id, depends_on: [])
      expect(epic.reload.depends_on_epics).to be_empty
    end

    it "is idempotent when the dependency row does not exist" do
      epic = Factories.epic(user: user, repository: repository)
      prerequisite = Factories.epic(user: user, repository: repository)

      2.times do
        response = call_tool("remove_epic_dependency", epic_id: epic.id, depends_on_epic_id: prerequisite.id)

        expect(response.dig(:result, :isError)).to be_falsey
        expect(payload(response)).to include(epic_id: epic.id, depends_on: [])
      end
    end

    it "allows an admin to unlink Epics across repositories/users" do
      admin = Factories.user(admin: true)
      other_user = Factories.user
      epic = Factories.epic(user: other_user, repository: Factories.repository(user: other_user))
      prerequisite = Factories.epic(user: other_user, repository: Factories.repository(user: other_user))
      EpicDependency.create!(epic: epic, depends_on_epic: prerequisite, derived: false)
      admin_session = ChatSession.create!(user: admin)
      admin_server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ Mcp::Tools::RemoveEpicDependencyTool ],
        server_context: { chat_session: admin_session }
      )

      raw = admin_server.handle_json({
        jsonrpc: "2.0", id: 1, method: "tools/call",
        params: { name: "remove_epic_dependency", arguments: { epic_id: epic.id, depends_on_epic_id: prerequisite.id } }
      }.to_json)
      response = JSON.parse(raw, symbolize_names: true)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(epic.reload.depends_on_epics).to be_empty
    end
  end
end
