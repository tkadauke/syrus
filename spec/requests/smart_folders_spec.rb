require "rails_helper"

RSpec.describe "Smart folders", type: :request do
  let(:user) { Factories.user }

  before { sign_in_as(user) }

  describe "POST /smart_folders" do
    it "creates an Epic smart folder and redirects to the Epic dashboard" do
      post smart_folders_path, params: {
        subject_type: "epic",
        state: "ready",
        smart_folder: { name: "Ready Epics" }
      }

      folder = user.smart_folders.find_by!(name: "Ready Epics")
      expect(folder.subject_type).to eq("epic")
      expect(folder.filter).to eq(
        "and" => [
          { "field" => "state", "op" => "is", "value" => "ready" }
        ]
      )
      expect(response).to redirect_to(epics_path(smart_folder_id: folder.id))
    end

    it "creates a Workflow smart folder and redirects to the Workflow dashboard" do
      post smart_folders_path, params: {
        subject_type: "workflow",
        state: "queued",
        smart_folder: { name: "Queued Workflows" }
      }

      folder = user.smart_folders.find_by!(name: "Queued Workflows")
      expect(folder.subject_type).to eq("workflow")
      expect(folder.filter).to eq(
        "and" => [
          { "field" => "state", "op" => "is", "value" => "queued" }
        ]
      )
      expect(response).to redirect_to(dashboard_workflows_path(smart_folder_id: folder.id))
    end
  end

  describe "GET /smart_folders" do
    it "lists only Epic smart folders when subject_type is epic" do
      job_folder = create_smart_folder(name: "Job folder", subject_type: "job")
      epic_folder = create_smart_folder(name: "Epic folder", subject_type: "epic")
      workflow_folder = create_smart_folder(name: "Workflow folder", subject_type: "workflow")

      get smart_folders_path, params: { subject_type: "epic" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(epic_folder.name)
      expect(response.body).not_to include(job_folder.name)
      expect(response.body).not_to include(workflow_folder.name)
    end

    it "defaults to listing only Job smart folders" do
      job_folder = create_smart_folder(name: "Job folder", subject_type: "job")
      epic_folder = create_smart_folder(name: "Epic folder", subject_type: "epic")
      workflow_folder = create_smart_folder(name: "Workflow folder", subject_type: "workflow")

      get smart_folders_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(job_folder.name)
      expect(response.body).not_to include(epic_folder.name)
      expect(response.body).not_to include(workflow_folder.name)
    end
  end

  def create_smart_folder(name:, subject_type:)
    user.smart_folders.create!(
      name: name,
      kind: "user_defined",
      subject_type: subject_type,
      filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "open" } ] },
      position: 0
    )
  end
end
