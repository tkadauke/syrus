require "rails_helper"

RSpec.describe "API: /api/v1/app/smart_folders", type: :request do
  let(:user) { Factories.user }
  let(:other) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/smart_folders"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "lists only the current user's smart folders for the selected subject" do
    sign_in_as(user)
    job_folder = create_smart_folder(user: user, name: "Job folder", subject_type: "job", position: 1)
    epic_folder = create_smart_folder(user: user, name: "Epic folder", subject_type: "epic", position: 2)
    create_smart_folder(user: other, name: "Other epic folder", subject_type: "epic", position: 0)

    get "/api/v1/app/smart_folders", params: { subject_type: "epic" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "subject_type" => "epic",
      "subject_label" => "Epic",
      "dashboard_path" => dashboard_epics_path
    )
    expect(body["smart_folders"]).to contain_exactly(
      include("id" => epic_folder.id, "name" => "Epic folder", "position" => 2)
    )
    expect(response.body).not_to include(job_folder.name)
    expect(response.body).not_to include("Other epic folder")
  end

  it "defaults to job smart folders" do
    sign_in_as(user)
    job_folder = create_smart_folder(user: user, name: "Job folder", subject_type: "job")
    create_smart_folder(user: user, name: "Epic folder", subject_type: "epic")

    get "/api/v1/app/smart_folders"

    expect(response).to have_http_status(:ok)
    expect(parse_body["subject_type"]).to eq("job")
    expect(parse_body["smart_folders"]).to contain_exactly(
      include("id" => job_folder.id, "name" => "Job folder")
    )
  end

  it "creates a smart folder from dashboard filter params" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/smart_folders", params: {
        subject_type: "epic",
        state: "ready",
        smart_folder: { name: "Ready Epics" }
      }
    }.to change { user.smart_folders.count }.by(1)

    folder = user.smart_folders.find_by!(name: "Ready Epics")
    expect(response).to have_http_status(:created)
    expect(folder).to have_attributes(subject_type: "epic", position: 0)
    expect(folder.filter).to eq("and" => [ { "field" => "state", "op" => "is", "value" => "ready" } ])
    expect(parse_body).to include(
      "message" => "Smart folder saved.",
      "redirect_to" => dashboard_epics_path(smart_folder_id: folder.id),
      "subject_type" => "epic"
    )
    expect(parse_body["smart_folder"]).to include("id" => folder.id, "name" => "Ready Epics")
  end

  it "creates an admin queue smart folder from a serialized filter tree" do
    sign_in_as(user)
    filter = { and: [ { field: "queue_name", op: "is", value: "runs" } ] }

    expect {
      post "/api/v1/app/smart_folders", params: {
        subject_type: "admin_queue",
        filter: filter.to_json,
        smart_folder: { name: "Runs queue" }
      }
    }.to change { user.smart_folders.count }.by(1)

    folder = user.smart_folders.find_by!(name: "Runs queue")
    expect(response).to have_http_status(:created)
    expect(folder).to have_attributes(subject_type: "admin_queue", position: 0)
    expect(folder.filter).to eq("and" => [ { "field" => "queue_name", "op" => "is", "value" => "runs" } ])
    expect(parse_body).to include(
      "message" => "Smart folder saved.",
      "redirect_to" => admin_queue_root_path(smart_folder_id: folder.id),
      "subject_type" => "admin_queue"
    )
    expect(parse_body["smart_folder"]).to include("id" => folder.id, "name" => "Runs queue")
  end

  it "rejects smart folder creation without filters" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/smart_folders", params: {
        subject_type: "job",
        smart_folder: { name: "Everything" }
      }
    }.not_to change { user.smart_folders.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("Choose at least one filter")
  end

  it "updates a smart folder" do
    sign_in_as(user)
    folder = create_smart_folder(user: user, name: "Old", subject_type: "workflow", position: 1)

    patch "/api/v1/app/smart_folders/#{folder.id}", params: {
      smart_folder: { name: "New", position: 4 }
    }

    expect(response).to have_http_status(:ok)
    expect(folder.reload.name).to eq("New")
    expect(folder.position).to eq(4)
    expect(parse_body["subject_type"]).to eq("workflow")
    expect(parse_body["message"]).to eq("Smart folder updated.")
  end

  it "returns validation errors" do
    sign_in_as(user)
    folder = create_smart_folder(user: user, name: "Old", subject_type: "job")

    patch "/api/v1/app/smart_folders/#{folder.id}", params: {
      smart_folder: { name: "" }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("Name")
  end

  it "deletes a smart folder" do
    sign_in_as(user)
    folder = create_smart_folder(user: user, name: "Delete me", subject_type: "job")

    expect {
      delete "/api/v1/app/smart_folders/#{folder.id}"
    }.to change { user.smart_folders.count }.by(-1)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Smart folder deleted.")
    expect(parse_body["smart_folders"]).to eq([])
  end

  it "does not allow managing another user's smart folders" do
    sign_in_as(user)
    folder = create_smart_folder(user: other, name: "Theirs", subject_type: "job")

    patch "/api/v1/app/smart_folders/#{folder.id}", params: {
      smart_folder: { name: "Stolen", position: 1 }
    }

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("not_found")
    expect(folder.reload.name).to eq("Theirs")
  end

  def create_smart_folder(user:, name:, subject_type:, position: 0)
    user.smart_folders.create!(
      name: name,
      kind: "user_defined",
      subject_type: subject_type,
      filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "open" } ] },
      position: position
    )
  end
end
