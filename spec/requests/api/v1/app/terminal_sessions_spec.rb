require "rails_helper"

RSpec.describe "App API terminal sessions", type: :request do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(repository: repo, issue_number: 42) }
  let(:workflow) { job.workflows.first }

  before do
    feature = Feature.find_or_create_by!(slug: "terminal") do |feature|
      feature.category = "Terminal"
      feature.name = "Terminal"
    end
    feature.update!(enabled: true)
  end

  def parse_body = JSON.parse(response.body)

  it "returns 404 for every endpoint when the terminal feature is disabled" do
    sign_in_as(user)
    session = TerminalSession.create!(
      user: user,
      name: "Shell",
      working_directory: "/tmp/shell",
      started_at: Time.current
    )
    Feature.find_by!(slug: "terminal").update!(enabled: false)

    get "/api/v1/app/terminal_sessions"
    expect(response).to have_http_status(:not_found)

    post "/api/v1/app/terminal_sessions", params: {}, as: :json
    expect(response).to have_http_status(:not_found)

    get "/api/v1/app/terminal_sessions/#{session.id}"
    expect(response).to have_http_status(:not_found)

    post "/api/v1/app/terminal_sessions/#{session.id}/kill", as: :json

    expect(response).to have_http_status(:not_found)
  end

  it "returns 401 for every endpoint when unauthenticated" do
    session = TerminalSession.create!(
      user: user,
      name: "Shell",
      working_directory: "/tmp/shell",
      started_at: Time.current
    )

    get "/api/v1/app/terminal_sessions"
    expect(response).to have_http_status(:unauthorized)

    post "/api/v1/app/terminal_sessions", params: {}, as: :json
    expect(response).to have_http_status(:unauthorized)

    get "/api/v1/app/terminal_sessions/#{session.id}"
    expect(response).to have_http_status(:unauthorized)

    post "/api/v1/app/terminal_sessions/#{session.id}/kill", as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it "lists the current user's running terminal sessions newest first" do
    sign_in_as(user)
    older = TerminalSession.create!(
      user: user,
      name: "Older",
      working_directory: "/tmp/older",
      started_at: 2.hours.ago
    )
    newer = TerminalSession.create!(
      user: user,
      name: "Newer",
      working_directory: "/tmp/newer",
      relay_address: "127.0.0.1:4000",
      started_at: 1.hour.ago
    )
    TerminalSession.create!(
      user: user,
      name: "Done",
      working_directory: "/tmp/done",
      started_at: 3.hours.ago,
      finished_at: 1.hour.ago,
      outcome: "exited"
    )
    TerminalSession.create!(
      user: other_user,
      name: "Other",
      working_directory: "/tmp/other",
      started_at: Time.current
    )

    get "/api/v1/app/terminal_sessions"

    expect(response).to have_http_status(:ok)
    expect(parse_body.map { |session| session["id"] }).to eq([ newer.id, older.id ])
    expect(parse_body.first).to include(
      "name" => "Newer",
      "working_directory" => "/tmp/newer",
      "relay_address" => "127.0.0.1:4000",
      "workflow_id" => nil
    )
    expect(parse_body.first).not_to have_key("auth_token")
  end

  it "creates a workflow-scoped terminal session and enqueues the relay job" do
    sign_in_as(user)
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new("/tmp/workflows/#{workflow.id}"))

    expect {
      post "/api/v1/app/terminal_sessions", params: { workflow_id: workflow.id, name: "Workspace shell" }, as: :json
    }.to change { TerminalSession.count }.by(1)
      .and have_enqueued_job(TerminalSessionJob)

    session = TerminalSession.last
    expect(response).to have_http_status(:created)
    expect(session.user).to eq(user)
    expect(session.workflow).to eq(workflow)
    expect(session.working_directory).to eq("/tmp/workflows/#{workflow.id}")
    expect(parse_body).to include(
      "id" => session.id,
      "name" => "Workspace shell",
      "working_directory" => "/tmp/workflows/#{workflow.id}",
      "workflow_id" => workflow.id
    )
    expect(parse_body).not_to have_key("auth_token")
  end

  it "uses the data root default when no workflow is supplied" do
    sign_in_as(user)

    post "/api/v1/app/terminal_sessions", params: {}, as: :json

    expect(response).to have_http_status(:created)
    expect(TerminalSession.last.working_directory).to eq(ENV.fetch("SYRUS_DATA_ROOT", "~/.syrus"))
  end

  it "shows a session scoped to the current user" do
    sign_in_as(user)
    session = TerminalSession.create!(
      user: user,
      workflow: workflow,
      name: "Shell",
      working_directory: "/tmp/shell",
      started_at: Time.current
    )

    get "/api/v1/app/terminal_sessions/#{session.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("id" => session.id, "workflow_id" => workflow.id)
  end

  it "does not show another user's session" do
    sign_in_as(user)
    session = TerminalSession.create!(
      user: other_user,
      name: "Other",
      working_directory: "/tmp/other",
      started_at: Time.current
    )

    get "/api/v1/app/terminal_sessions/#{session.id}"

    expect(response).to have_http_status(:not_found)
  end

  it "kills the current user's session" do
    sign_in_as(user)
    session = TerminalSession.create!(
      user: user,
      name: "Shell",
      working_directory: "/tmp/shell",
      started_at: Time.current
    )

    post "/api/v1/app/terminal_sessions/#{session.id}/kill", as: :json

    expect(response).to have_http_status(:ok)
    expect(session.reload.outcome).to eq("killed")
    expect(session.finished_at).to be_present
    expect(parse_body).to include("outcome" => "killed")
  end

  it "does not kill another user's session" do
    sign_in_as(user)
    session = TerminalSession.create!(
      user: other_user,
      name: "Other",
      working_directory: "/tmp/other",
      started_at: Time.current
    )

    post "/api/v1/app/terminal_sessions/#{session.id}/kill", as: :json

    expect(response).to have_http_status(:not_found)
    expect(session.reload.outcome).to be_nil
    expect(session.finished_at).to be_nil
  end
end
