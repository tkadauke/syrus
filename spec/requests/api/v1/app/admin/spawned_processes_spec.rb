require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/processes", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end

  def parse_body
    JSON.parse(response.body)
  end

  def fixture(**overrides)
    SpawnedProcess.create!({
      kind: "agent",
      command: "claude --print",
      hostname: "syrus-worker-test",
      started_at: 30.seconds.ago,
      last_chunk_at: 5.seconds.ago
    }.merge(overrides))
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/processes"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/processes"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns the default active and recent process inventory" do
    sign_in_as(admin)
    running = fixture
    fixture(started_at: 5.hours.ago, finished_at: 4.hours.ago, outcome: "succeeded", exit_status: 0)

    get "/api/v1/app/admin/processes"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["processes"].map { |process| process["id"] }).to include(running.id)
    expect(body["running_total"]).to eq(SpawnedProcess.running.count)
    expect(body["filter"]).to eq("and" => [])
    expect(body.dig("controls", "filter_schema").map { |field| field["field"] }).to include("state", "kind", "hostname")
    expect(body["smart_folders"].find { |folder| folder["name"] == "Running" }).to include(
      "count" => 1,
      "path" => a_string_matching(%r{\A/admin/processes\?smart_folder_id=})
    )
  end

  it "filters the process inventory" do
    sign_in_as(admin)
    fixture(kind: "agent")
    grader = fixture(kind: "grader", command: "bin/rspec")

    get "/api/v1/app/admin/processes", params: { kind: "grader", state: "running" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["processes"].map { |process| process["id"] }).to eq([ grader.id ])
    expect(body["filter"]).to eq(
      "and" => [
        { "field" => "state", "op" => "is", "value" => "running" },
        { "field" => "kind", "op" => "is", "value" => "grader" }
      ]
    )
  end

  it "applies spawned process smart folders" do
    sign_in_as(admin)
    SmartFolder.ensure_spawned_process_builtins!
    running = fixture
    fixture(started_at: 5.hours.ago, finished_at: 4.hours.ago, outcome: "succeeded", exit_status: 0)
    folder = SmartFolder.for_subject(:spawned_process).find_by!(name: "Running")

    get "/api/v1/app/admin/processes", params: { smart_folder_id: folder.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["active_smart_folder_id"]).to eq(folder.id)
    expect(body["processes"].map { |process| process["id"] }).to eq([ running.id ])
    expect(body["smart_folders"].find { |row| row["id"] == folder.id }).to include("active" => true, "count" => 1)
  end

  it "returns the active user-defined process folder filter when no q is present" do
    sign_in_as(admin)
    running = fixture(kind: "agent")
    fixture(kind: "grader", started_at: 5.hours.ago, finished_at: 4.hours.ago, outcome: "succeeded", exit_status: 0)
    folder_tree = {
      "and" => [
        { "field" => "state", "op" => "is", "value" => "running" }
      ]
    }
    folder = admin.smart_folders.create!(
      name: "Running processes",
      kind: "user_defined",
      subject_type: "spawned_process",
      filter: folder_tree,
      position: 0
    )

    get "/api/v1/app/admin/processes", params: { smart_folder_id: folder.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["filter"]).to eq(folder_tree)
    expect(body["processes"].map { |process| process["id"] }).to eq([ running.id ])
  end

  it "returns only the URL process filter when a user-defined folder also has q" do
    sign_in_as(admin)
    fixture(kind: "agent")
    running_grader = fixture(kind: "grader", command: "bin/rspec")
    finished_grader = fixture(kind: "grader", command: "bin/rubocop", started_at: 5.hours.ago, finished_at: 4.hours.ago, outcome: "succeeded", exit_status: 0)
    folder_tree = {
      "and" => [
        { "field" => "state", "op" => "is", "value" => "running" }
      ]
    }
    url_tree = {
      "and" => [
        { "field" => "kind", "op" => "is", "value" => "grader" }
      ]
    }
    folder = admin.smart_folders.create!(
      name: "Running processes",
      kind: "user_defined",
      subject_type: "spawned_process",
      filter: folder_tree,
      position: 0
    )

    get "/api/v1/app/admin/processes", params: { smart_folder_id: folder.id, q: Filters::QueryParam.encode(url_tree) }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["filter"]).to eq(url_tree)
    expect(body["processes"].map { |process| process["id"] }).to contain_exactly(running_grader.id, finished_grader.id)
  end

  it "returns process detail with host metrics key" do
    sign_in_as(admin)
    job = Factories.job(user: admin)
    workflow = job.latest_workflow
    process = fixture(workflow: workflow)

    get "/api/v1/app/admin/processes/#{process.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "id" => process.id,
      "kind" => "agent",
      "workflow_id" => workflow.id,
      "workflow_slug" => "WF-#{workflow.id}",
      "workflow_path" => "/jobs/#{job.id}?tab=workflows#workflow-#{workflow.id}",
      "host_metrics" => nil
    )
  end

  it "stamps kill_requested_at" do
    sign_in_as(admin)
    process = fixture

    expect {
      post "/api/v1/app/admin/processes/#{process.id}/kill"
    }.to change { process.reload.kill_requested_at }.from(nil)

    expect(response).to have_http_status(:ok)
    expect(parse_body["kill_requested_at"]).to be_present
    expect(process.kill_requested_by_user).to eq(admin)
  end

  it "returns 409 if the process is already finished" do
    sign_in_as(admin)
    process = fixture(finished_at: Time.current, outcome: "succeeded", exit_status: 0)

    post "/api/v1/app/admin/processes/#{process.id}/kill"

    expect(response).to have_http_status(:conflict)
    expect(parse_body.dig("error", "code")).to eq("already_finished")
  end
end
