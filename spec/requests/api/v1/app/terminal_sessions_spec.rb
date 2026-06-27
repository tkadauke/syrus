require "rails_helper"

RSpec.describe "API: /api/v1/app/terminal_sessions", type: :request do
  let(:user) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  def enable_terminal
    Feature.create!(slug: "terminal", category: "labs", name: "Terminal", enabled: true)
  end

  it "401s when signed out" do
    get "/api/v1/app/terminal_sessions"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "404s when the terminal feature is disabled" do
    sign_in_as(user)

    get "/api/v1/app/terminal_sessions"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("terminal_disabled")
  end

  it "lists current-user running sessions and recent workflow workspaces" do
    enable_terminal
    sign_in_as(user)
    other = Factories.user
    job = Factories.job(user: user, repository: Factories.repository(user: user), issue_title: "Build terminal UI")
    workflow = job.workflows.first
    running = TerminalSession.create!(
      user: user,
      workflow: workflow,
      name: "WF shell",
      working_directory: "/tmp/workflow",
      started_at: Time.current
    )
    TerminalSession.create!(
      user: user,
      name: "done",
      working_directory: "/tmp/done",
      started_at: Time.current,
      finished_at: Time.current,
      outcome: "exited"
    )
    TerminalSession.create!(
      user: other,
      name: "theirs",
      working_directory: "/tmp/theirs",
      started_at: Time.current
    )

    get "/api/v1/app/terminal_sessions"

    expect(response).to have_http_status(:ok)
    expect(parse_body["sessions"].map { |session| session["id"] }).to eq([ running.id ])
    expect(parse_body["sessions"].first).to include(
      "name" => "WF shell",
      "working_directory" => "/tmp/workflow",
      "workflow_id" => workflow.id,
      "finished_at" => nil
    )
    expect(parse_body["workspaces"].first).to include("label" => "Scratch", "kind" => "scratch")
    expect(parse_body["workspaces"].second).to include(
      "id" => workflow.id,
      "label" => "WF-#{workflow.id} - Build terminal UI",
      "kind" => "workflow"
    )
  end

  it "creates and kills a terminal session" do
    enable_terminal
    sign_in_as(user)
    job = Factories.job(user: user, repository: Factories.repository(user: user), issue_title: "Investigate flakes")
    workflow = job.workflows.first

    post "/api/v1/app/terminal_sessions", params: {
      terminal_session: {
        workflow_id: workflow.id,
        name: "Debug",
        working_directory: "/ignored"
      }
    }

    expect(response).to have_http_status(:created)
    session = TerminalSession.find(parse_body.dig("session", "id"))
    expect(session).to have_attributes(
      user_id: user.id,
      workflow_id: workflow.id,
      name: "Debug",
      working_directory: WorkflowWorkspace.path_for(workflow).to_s,
      finished_at: nil
    )

    delete "/api/v1/app/terminal_sessions/#{session.id}"

    expect(response).to have_http_status(:ok)
    expect(session.reload).to be_finished
    expect(session.outcome).to eq("killed")
    expect(parse_body.dig("session", "finished_at")).to be_present
  end
end
