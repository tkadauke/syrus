require "rails_helper"

RSpec.describe "Mcp::Tools epic kanban tools" do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        Mcp::Tools::ListEpicsTool,
        Mcp::Tools::StartEpicTool,
        Mcp::Tools::MoveEpicToBacklogTool,
        Mcp::Tools::ArchiveEpicTool,
        Mcp::Tools::UpdateEpicTool
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

  describe "list_epics" do
    it "allows an admin to list Epics owned by any user" do
      admin = Factories.user(admin: true)
      other_user = Factories.user
      other_epic = Factories.epic(user: other_user, repository: Factories.repository(user: other_user), title: "Other")
      admin_session = ChatSession.create!(user: admin)
      admin_server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ Mcp::Tools::ListEpicsTool ],
        server_context: { chat_session: admin_session }
      )

      raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_epics", arguments: {} } }.to_json)
      result = payload(JSON.parse(raw, symbolize_names: true))

      expect(result[:epics].pluck(:id)).to include(other_epic.id)
    end

    it "lists non-archived Epics across the user's repositories by default with child Job counts" do
      backlog = Factories.epic(user: user, repository: repository, title: "Backlog", description: "a" * 250)
      ready = Factories.epic(user: user, repository: repository, title: "Ready", state: "ready")
      archived = Factories.epic(user: user, repository: repository, title: "Archived")
      archived.archive!
      other_repository = Factories.repository(user: user)
      other = Factories.epic(user: user, repository: other_repository, title: "Other")
      Factories.epic(title: "Outsider")
      Factories.job_record(user: user, repository: repository, epic: ready, state: "queued")
      Factories.job_record(user: user, repository: repository, epic: ready, state: "closed")

      result = payload(call_tool("list_epics", limit: 10))

      expect(result[:epics].pluck(:id)).to eq([ other.id, ready.id, backlog.id ])
      expect(result[:epics].find { |epic| epic[:id] == ready.id }).to include(
        repository_slug: repository.slug,
        title: "Ready",
        state: "ready",
        child_job_count: 2,
        open_job_count: 1
      )
      expect(result[:epics].find { |epic| epic[:id] == other.id }).to include(repository_slug: other_repository.slug)
      expect(result[:epics].find { |epic| epic[:id] == backlog.id }[:description].length).to eq(200)
      expect(result[:epics].pluck(:id)).not_to include(archived.id)
    end

    it "filters by state" do
      ready = Factories.epic(user: user, repository: repository, title: "Ready", state: "ready")
      Factories.epic(user: user, repository: repository, title: "Backlog")

      result = payload(call_tool("list_epics", state: "ready"))

      expect(result[:epics].pluck(:id)).to eq([ ready.id ])
    end

    it "rejects unknown states" do
      response = call_tool("list_epics", state: "waiting")

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("state must be one of backlog, ready, in_progress, done, archived")
    end

    it "works without a repository pinned to the chat session" do
      chat_session.update!(repository: nil)
      epic = Factories.epic(user: user, repository: repository, title: "Backlog")

      result = payload(call_tool("list_epics"))

      expect(result[:epics].pluck(:id)).to eq([ epic.id ])
    end
  end

  describe "start_epic" do
    it "starts a ready Epic and claims it for the chat user" do
      epic = Factories.epic(user: user, repository: repository, state: "ready")

      result = payload(call_tool("start_epic", epic_id: epic.id))

      expect(result).to include(epic_id: epic.id, previous_state: "ready", new_state: "in_progress")
      expect(epic.reload).to be_in_progress
      expect(epic.claimed_by?(user)).to be true
    end

    it "rejects Epics outside the chat repository" do
      epic = Factories.epic(user: user, repository: Factories.repository(user: user), state: "ready")

      response = call_tool("start_epic", epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("epic not found in this repository")
    end

    it "allows an admin to start another user's Epic regardless of chat repository" do
      admin = Factories.user(admin: true)
      other_user = Factories.user
      other_epic = Factories.epic(user: other_user, repository: Factories.repository(user: other_user), state: "ready")
      admin_session = ChatSession.create!(user: admin)
      admin_server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ Mcp::Tools::StartEpicTool ],
        server_context: { chat_session: admin_session }
      )

      raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "start_epic", arguments: { epic_id: other_epic.id } } }.to_json)
      response = JSON.parse(raw, symbolize_names: true)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(other_epic.reload).to be_in_progress
    end

    it "rejects Epics that are not ready" do
      epic = Factories.epic(user: user, repository: repository)

      response = call_tool("start_epic", epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("epic must be ready to start; current state is backlog")
      expect(epic.reload).to be_backlog
    end

    it "rejects product owners" do
      user.update!(role: "product_owner")
      epic = Factories.epic(user: user, repository: repository, state: "ready")

      response = call_tool("start_epic", epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("Product owners cannot advance Epics beyond backlog.")
      expect(epic.reload).to be_ready
    end
  end

  describe "move_epic_to_backlog" do
    it "moves a ready Epic to backlog" do
      epic = Factories.epic(user: user, repository: repository, state: "ready")

      result = payload(call_tool("move_epic_to_backlog", epic_id: epic.id))

      expect(result).to include(epic_id: epic.id, previous_state: "ready", new_state: "backlog")
      expect(epic.reload).to be_backlog
    end

    it "rejects Epics outside the chat repository" do
      epic = Factories.epic(user: user, repository: Factories.repository(user: user), state: "ready")

      response = call_tool("move_epic_to_backlog", epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("epic not found in this repository")
    end

    it "allows an admin to move another user's Epic back to backlog regardless of chat repository" do
      admin = Factories.user(admin: true)
      other_user = Factories.user
      other_epic = Factories.epic(user: other_user, repository: Factories.repository(user: other_user), state: "ready")
      admin_session = ChatSession.create!(user: admin)
      admin_server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ Mcp::Tools::MoveEpicToBacklogTool ],
        server_context: { chat_session: admin_session }
      )

      raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "move_epic_to_backlog", arguments: { epic_id: other_epic.id } } }.to_json)
      response = JSON.parse(raw, symbolize_names: true)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(other_epic.reload).to be_backlog
    end

    it "rejects Epics that are not ready" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")

      response = call_tool("move_epic_to_backlog", epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("epic must be ready to move to backlog; current state is in_progress")
      expect(epic.reload).to be_in_progress
    end
  end

  describe "archive_epic" do
    it "archives an active Epic" do
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")

      result = payload(call_tool("archive_epic", epic_id: epic.id))

      expect(result).to include(epic_id: epic.id, previous_state: "in_progress", new_state: "archived")
      expect(epic.reload).to be_archived
    end

    it "rejects Epics outside the chat repository" do
      epic = Factories.epic(user: user, repository: Factories.repository(user: user), state: "ready")

      response = call_tool("archive_epic", epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("epic not found in this repository")
    end

    it "allows an admin to archive another user's Epic regardless of chat repository" do
      admin = Factories.user(admin: true)
      other_user = Factories.user
      other_epic = Factories.epic(user: other_user, repository: Factories.repository(user: other_user), state: "in_progress")
      admin_session = ChatSession.create!(user: admin)
      admin_server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ Mcp::Tools::ArchiveEpicTool ],
        server_context: { chat_session: admin_session }
      )

      raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "archive_epic", arguments: { epic_id: other_epic.id } } }.to_json)
      response = JSON.parse(raw, symbolize_names: true)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(other_epic.reload).to be_archived
    end

    it "rejects Epics that are already archived" do
      epic = Factories.epic(user: user, repository: repository, state: "ready")
      epic.archive!

      response = call_tool("archive_epic", epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("epic is already archived")
      expect(epic.reload).to be_archived
    end
  end

  describe "update_epic" do
    it "updates provided Epic fields" do
      epic = Factories.epic(user: user, repository: repository, title: "Old", description: "Old description")

      result = payload(call_tool("update_epic", epic_id: epic.id, title: "New", description: "New description"))

      expect(result).to include(epic_id: epic.id, title: "New", description: "New description", state: "backlog")
      expect(epic.reload).to have_attributes(title: "New", description: "New description")
    end

    it "updates Epics outside the chat repository when they belong to the chat user" do
      epic = Factories.epic(user: user, repository: Factories.repository(user: user), title: "Old")

      response = call_tool("update_epic", epic_id: epic.id, title: "New")

      expect(response.dig(:result, :isError)).to be_falsey
      expect(epic.reload.title).to eq("New")
    end

    it "rejects Epics owned by another user" do
      other_user = Factories.user
      other_epic = Factories.epic(user: other_user, repository: Factories.repository(user: other_user))

      response = call_tool("update_epic", epic_id: other_epic.id, title: "New")

      expect(response.dig(:result, :isError)).to be true
      expect(payload(response)).to eq(error: "not_authorized")
    end

    it "allows an admin to update another user's Epic" do
      admin = Factories.user(admin: true)
      other_user = Factories.user
      other_epic = Factories.epic(user: other_user, repository: Factories.repository(user: other_user), title: "Old")
      admin_session = ChatSession.create!(user: admin)
      admin_server = MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [ Mcp::Tools::UpdateEpicTool ],
        server_context: { chat_session: admin_session }
      )

      raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "update_epic", arguments: { epic_id: other_epic.id, title: "Admin update" } } }.to_json)
      response = JSON.parse(raw, symbolize_names: true)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(other_epic.reload.title).to eq("Admin update")
    end

    it "rejects updates without a title or description" do
      epic = Factories.epic(user: user, repository: repository)

      response = call_tool("update_epic", epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("title or description is required")
      expect(epic.reload.title).not_to be_empty
    end

    it "rejects archived Epics" do
      epic = Factories.epic(user: user, repository: repository, state: "ready")
      epic.archive!

      response = call_tool("update_epic", epic_id: epic.id, title: "New")

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("archived epics cannot be updated")
    end
  end
end
