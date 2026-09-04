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

  it "lists current-user running sessions and recent workflow workspaces" do
    sign_in_as(user)
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new("/tmp/workflows/#{workflow.id}"))
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
    expect(parse_body["workspaces"].first).to include("label" => "Scratch", "kind" => "scratch")
    expect(parse_body["workspaces"].second).to include(
      "id" => workflow.id,
      "label" => "WF-#{workflow.id} - Build terminal UI",
      "working_directory" => "/tmp/workflows/#{workflow.id}",
      "kind" => "workflow"
    )
  end

  it "creates a workflow-scoped terminal session and enqueues the relay job" do
    sign_in_as(user)
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new("/tmp/workflows/#{workflow.id}"))

    expect {
      post "/api/v1/app/terminal_sessions", params: { terminal_session: { workflow_id: workflow.id, name: "Workspace shell", working_directory: "/ignored" } }, as: :json
    }.to change { Terminal::Session.count }.by(1)
      .and have_enqueued_job(TerminalSessionJob).on_queue("chat")

    session = Terminal::Session.last
    expect(response).to have_http_status(:created)
    expect(session.user).to eq(user)
    expect(session.workflow).to eq(workflow)
    expect(session.working_directory).to eq("/tmp/workflows/#{workflow.id}")
    expect(session.auth_token).to match(/\A\h{64}\z/)
    expect(parse_body["session"]).to include(
      "id" => session.id,
      "name" => "Workspace shell",
      "working_directory" => "/tmp/workflows/#{workflow.id}",
      "workflow_id" => workflow.id
    )
    expect(parse_body["session"]).not_to have_key("auth_token")
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
