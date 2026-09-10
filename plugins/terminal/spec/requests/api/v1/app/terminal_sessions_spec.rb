require "rails_helper"

RSpec.describe "App API terminal sessions", type: :request do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(user: user, repository: repo, issue_number: 42, issue_title: "Build terminal UI") }
  let(:workflow) { job.workflows.first }

  before do
    PluginRecord.find_or_create_by!(name: "terminal").update!(enabled: true, disableable: true)
  end

  def parse_body = JSON.parse(response.body)

  def workflow_workspace_path(workflow)
    WorkflowWorkspace.path_for(workflow)
  end

  def create_workflow_workspace!(workflow)
    FileUtils.mkdir_p(workflow_workspace_path(workflow))
  end

  def live_worker_queue!(queue_name, hostname: "syrus-worker-1")
    ensure_solid_queue_test_tables!
    SolidQueue::Process.create!(
      hostname: hostname,
      kind: "worker",
      last_heartbeat_at: Time.current,
      metadata: { "queues" => [ queue_name, "chat", "runs" ] },
      name: "#{hostname}:1",
      pid: 123,
      created_at: Time.current
    )
    InstanceVersion.create!(
      hostname: hostname,
      role: "worker",
      version: "test",
      started_at: Time.current,
      last_heartbeat_at: Time.current,
      data_root_path: "/syrus-data/#{hostname}"
    )
  end

  it "returns 404 for every endpoint when the terminal plugin is disabled" do
    sign_in_as(user)
    session = Terminal::Session.create!(
      user: user,
      name: "Shell",
      working_directory: "/tmp/shell",
      auth_token: SecureRandom.hex(32),
      started_at: Time.current
    )
    PluginRecord.find_by!(name: "terminal").update!(enabled: false)

    get "/api/v1/app/terminal_sessions"
    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")

    post "/api/v1/app/terminal_sessions", params: {}, as: :json
    expect(response).to have_http_status(:not_found)

    get "/api/v1/app/terminal_sessions/#{session.id}"
    expect(response).to have_http_status(:not_found)

    delete "/api/v1/app/terminal_sessions/#{session.id}", as: :json
    expect(response).to have_http_status(:not_found)

    post "/api/v1/app/terminal_sessions/#{session.id}/kill", as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "returns 401 for every endpoint when unauthenticated" do
    session = Terminal::Session.create!(
      user: user,
      name: "Shell",
      working_directory: "/tmp/shell",
      auth_token: SecureRandom.hex(32),
      started_at: Time.current
    )

    get "/api/v1/app/terminal_sessions"
    expect(response).to have_http_status(:unauthorized)

    post "/api/v1/app/terminal_sessions", params: {}, as: :json
    expect(response).to have_http_status(:unauthorized)

    get "/api/v1/app/terminal_sessions/#{session.id}"
    expect(response).to have_http_status(:unauthorized)

    delete "/api/v1/app/terminal_sessions/#{session.id}", as: :json
    expect(response).to have_http_status(:unauthorized)

    post "/api/v1/app/terminal_sessions/#{session.id}/kill", as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "lists current-user running sessions and structured terminal workspace candidates" do
    sign_in_as(user)
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new("/tmp/workflows/#{workflow.id}"))
    workflow.update_columns(state: "failed", worker_hostname: "worker-a", worker_storage_key: "storage-a")
    live_worker_queue!("resume-storage-a", hostname: "worker-a")
    older = Terminal::Session.create!(
      user: user,
      name: "Older",
      working_directory: "/tmp/older",
      auth_token: SecureRandom.hex(32),
      started_at: 2.hours.ago
    )
    newer = Terminal::Session.create!(
      user: user,
      workflow: workflow,
      name: "Newer",
      working_directory: "/tmp/newer",
      relay_address: "127.0.0.1:4000",
      auth_token: SecureRandom.hex(32),
      started_at: 1.hour.ago
    )
    Terminal::Session.create!(
      user: user,
      name: "Done",
      working_directory: "/tmp/done",
      auth_token: SecureRandom.hex(32),
      started_at: 3.hours.ago,
      finished_at: 1.hour.ago,
      outcome: "exited"
    )
    Terminal::Session.create!(
      user: other_user,
      name: "Other",
      working_directory: "/tmp/other",
      auth_token: SecureRandom.hex(32),
      started_at: Time.current
    )

    get "/api/v1/app/terminal_sessions"

    expect(response).to have_http_status(:ok)
    expect(parse_body["sessions"].map { |session| session["id"] }).to eq([ newer.id, older.id ])
    expect(parse_body["sessions"].first).to include(
      "name" => "Newer",
      "working_directory" => "/tmp/newer",
      "relay_address" => "127.0.0.1:4000",
      "workflow_id" => workflow.id
    )
    expect(parse_body["sessions"].first).not_to have_key("auth_token")

    expect(parse_body["workspaces"].first).to include(
      "id" => workflow.id,
      "label" => "WF-#{workflow.id} - Build terminal UI",
      "working_directory" => "/tmp/workflows/#{workflow.id}",
      "kind" => "workflow",
      "section" => "interesting_workflows",
      "section_title" => "Interesting workflows",
      "worker_hostname" => "worker-a",
      "worker_storage_key" => "storage-a",
      "queue_name" => "resume-storage-a",
      "available" => true
    )
    expect(parse_body["workspaces"]).to include(
      hash_including(
        "label" => "Scratch on worker-a",
        "kind" => "worker",
        "section" => "workers",
        "worker_hostname" => "worker-a",
        "worker_storage_key" => "storage-a",
        "queue_name" => "resume-storage-a"
      )
    )
  end

  it "creates a workflow-scoped terminal session from a candidate and enqueues the relay job on its storage route" do
    sign_in_as(user)
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new("/tmp/workflows/#{workflow.id}"))
    workflow.update_columns(worker_hostname: "worker-a", worker_storage_key: "storage-a")
    live_worker_queue!("resume-storage-a", hostname: "worker-a")

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { candidate_key: "workflow:#{workflow.id}", name: "Workspace shell", working_directory: "/ignored" } }, as: :json
    }.to change { Terminal::Session.count }.by(1)
      .and have_enqueued_job(TerminalSessionJob).on_queue("resume-storage-a")

    session = Terminal::Session.last
    expect(response).to have_http_status(:created)
    expect(session.user).to eq(user)
    expect(session.workflow).to eq(workflow)
    expect(session.working_directory).to eq("/tmp/workflows/#{workflow.id}")
    expect(session.worker_hostname).to eq("worker-a")
    expect(session.worker_storage_key).to eq("storage-a")
    expect(session.queue_name).to eq("resume-storage-a")
    expect(session.workspace_kind).to eq("workflow")
    expect(session.auth_token).to match(/\A\h{64}\z/)
    expect(parse_body["session"]).to include(
      "id" => session.id,
      "name" => "Workspace shell",
      "working_directory" => "/tmp/workflows/#{workflow.id}",
      "workflow_id" => workflow.id,
      "worker_storage_key" => "storage-a",
      "queue_name" => "resume-storage-a"
    )
    expect(parse_body["session"]).not_to have_key("auth_token")
  end

  it "creates a worker scratch terminal from a candidate and routes it to the selected storage queue" do
    sign_in_as(user)
    live_worker_queue!("resume-storage-b", hostname: "worker-b")

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { candidate_key: "worker:worker-b:storage-b" } }, as: :json
    }.to change { Terminal::Session.count }.by(1)
      .and have_enqueued_job(TerminalSessionJob).on_queue("resume-storage-b")

    session = Terminal::Session.last
    expect(response).to have_http_status(:created)
    expect(session.name).to eq("Scratch on worker-b")
    expect(session.working_directory).to eq(Rails.root.to_s)
    expect(session.workflow).to be_nil
    expect(session.worker_hostname).to eq("worker-b")
    expect(session.worker_storage_key).to eq("storage-b")
    expect(session.workspace_kind).to eq("worker")
  end

  it "creates a chat workspace terminal from a candidate" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, mode: "coding", repository: repo, title: "Fix terminal picker")
    chat_workspace_path = Rails.root.join("tmp", "spec-chat-workspaces", chat.id.to_s)
    FileUtils.mkdir_p(chat_workspace_path)
    chat.update_columns(workspace_path: chat_workspace_path.to_s, coding_checkout_branch: "main")

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { candidate_key: "chat:#{chat.id}" } }, as: :json
    }.to change { Terminal::Session.count }.by(1)
      .and have_enqueued_job(TerminalSessionJob).on_queue("chat")

    session = Terminal::Session.last
    expect(response).to have_http_status(:created)
    expect(session.chat_session).to eq(chat)
    expect(session.name).to eq("Chat ##{chat.id} - Fix terminal picker")
    expect(session.working_directory).to eq(chat_workspace_path.to_s)
    expect(session.workspace_kind).to eq("chat")
  end

  it "does not create a terminal session for an unmaterialized chat workspace candidate" do
    sign_in_as(user)
    chat = ChatSession.create!(user: user, mode: "coding", repository: repo, title: "Unmaterialized chat")
    chat.update_columns(workspace_path: Rails.root.join("tmp", "missing-chat-workspace-#{chat.id}").to_s)

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { candidate_key: "chat:#{chat.id}" } }, as: :json
    }.not_to change { Terminal::Session.count }

    expect(response).to have_http_status(:not_found)
  end

  it "does not create a terminal session from another user's chat candidate" do
    sign_in_as(user)
    chat = ChatSession.create!(user: other_user, mode: "coding", repository: Factories.repository(user: other_user), title: "Other chat")

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { candidate_key: "chat:#{chat.id}" } }, as: :json
    }.not_to change { Terminal::Session.count }

    expect(response).to have_http_status(:not_found)
  end

  it "rejects a workflow-scoped terminal session when the workspace was cleaned up" do
    sign_in_as(user)
    create_workflow_workspace!(workflow)
    workflow.update!(cleaned_up_at: Time.current)

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { workflow_id: workflow.id, name: "Workspace shell" } }, as: :json
    }.not_to change { Terminal::Session.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("This workflow workspace has been cleaned up.")
  end

  it "rejects a workflow-scoped terminal session when the local workspace path is missing" do
    sign_in_as(user)
    FileUtils.rm_rf(workflow_workspace_path(workflow))

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { workflow_id: workflow.id, name: "Workspace shell" } }, as: :json
    }.not_to change { Terminal::Session.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("This workflow workspace is not present on this storage root.")
  end

  it "rejects a workflow-scoped terminal session when the owning storage queue is dead" do
    sign_in_as(user)
    workflow.update!(worker_storage_key: "storage-dead")

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { workflow_id: workflow.id, name: "Workspace shell" } }, as: :json
    }.not_to change { Terminal::Session.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("This workflow workspace is on a worker storage root that is not currently reachable.")
  end

  it "rejects a workflow-scoped terminal session when the owning remote worker is dead" do
    sign_in_as(user)
    workflow.update!(worker_hostname: "syrus-worker-dead")

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { workflow_id: workflow.id, name: "Workspace shell" } }, as: :json
    }.not_to change { Terminal::Session.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to eq("This workflow workspace is on a worker that is not currently reachable.")
  end

  it "routes a workflow-scoped terminal session to the live owning storage queue" do
    sign_in_as(user)
    workflow.update!(worker_storage_key: "storage-a")
    live_worker_queue!("resume-storage-a")

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { workflow_id: workflow.id, name: "Workspace shell" } }, as: :json
    }.to change { Terminal::Session.count }.by(1)
      .and have_enqueued_job(TerminalSessionJob).on_queue("resume-storage-a")

    expect(response).to have_http_status(:created)
    expect(Terminal::Session.last.working_directory).to eq(workflow_workspace_path(workflow).to_s)
  end

  it "uses the scratch working directory when no workflow is supplied" do
    sign_in_as(user)

    post "/api/v1/app/terminal_sessions", params: { terminal_session: { name: "Scratch" } }, as: :json
    expect(response).to have_http_status(:created)
    expect(Terminal::Session.last.working_directory).to eq(Rails.root.to_s)
  end

  it "shows a session scoped to the current user" do
    sign_in_as(user)
    session = Terminal::Session.create!(
      user: user,
      workflow: workflow,
      name: "Shell",
      working_directory: "/tmp/shell",
      auth_token: SecureRandom.hex(32),
      started_at: Time.current
    )
    expect(session.auth_token).to match(/\A\h{64}\z/)

    get "/api/v1/app/terminal_sessions/#{session.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["session"]).to include("id" => session.id, "workflow_id" => workflow.id)
    expect(parse_body["session"]).not_to have_key("auth_token")
  end

  it "does not show another user's session" do
    sign_in_as(user)
    session = Terminal::Session.create!(
      user: other_user,
      name: "Other",
      working_directory: "/tmp/other",
      auth_token: SecureRandom.hex(32),
      started_at: Time.current
    )

    get "/api/v1/app/terminal_sessions/#{session.id}"

    expect(response).to have_http_status(:not_found)
  end

  it "kills the current user's session" do
    sign_in_as(user)
    session = Terminal::Session.create!(
      user: user,
      name: "Shell",
      working_directory: "/tmp/shell",
      auth_token: SecureRandom.hex(32),
      started_at: Time.current
    )

    delete "/api/v1/app/terminal_sessions/#{session.id}", as: :json

    expect(response).to have_http_status(:ok)
    expect(session.reload.outcome).to eq("killed")
    expect(session.finished_at).to be_present
    expect(parse_body.dig("session", "outcome")).to eq("killed")
  end

  it "supports the legacy kill endpoint" do
    sign_in_as(user)
    session = Terminal::Session.create!(
      user: user,
      name: "Shell",
      working_directory: "/tmp/shell",
      auth_token: SecureRandom.hex(32),
      started_at: Time.current
    )

    post "/api/v1/app/terminal_sessions/#{session.id}/kill", as: :json

    expect(response).to have_http_status(:ok)
    expect(session.reload.outcome).to eq("killed")
    expect(parse_body.dig("session", "finished_at")).to be_present
  end

  it "does not kill another user's session" do
    sign_in_as(user)
    session = Terminal::Session.create!(
      user: other_user,
      name: "Other",
      working_directory: "/tmp/other",
      auth_token: SecureRandom.hex(32),
      started_at: Time.current
    )

    delete "/api/v1/app/terminal_sessions/#{session.id}", as: :json

    expect(response).to have_http_status(:not_found)
    expect(session.reload.outcome).to be_nil
    expect(session.finished_at).to be_nil
  end
end
