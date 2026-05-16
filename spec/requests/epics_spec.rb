require "rails_helper"

RSpec.describe "Epics", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  describe "GET /epics/:id" do
    it "requires authentication" do
      epic = Factories.epic(user: user, repository: repo)

      get epic_path(epic)

      expect(response).to redirect_to(new_session_path)
    end

    it "shows the dependency graph expanded for small Epics" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, title: "Restore forum")
      Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 10, issue_title: "Set stones")

      get epic_path(epic)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Restore forum")
      expect(response.body).to include("Dependency graph")
      expect(response.body).to include("data-controller=\"mermaid-graph\"")
      expect(response.body).to include("job_")
      expect(response.body).to match(/<details[^>]*open[^>]*>.*Dependency graph/m)
    end

    it "toggles the dependency graph between adjacent and transitive depth" do
      sign_in_as(user)
      root = Factories.epic(user: user, repository: repo, title: "Restore forum")
      middle = Factories.epic(user: user, repository: repo, title: "Repair road")
      leaf = Factories.epic(user: user, repository: repo, title: "Deliver marble")
      root_job = Factories.job_record(user: user, repository: repo, epic: root, issue_number: 20, issue_title: "Survey")
      middle_job = Factories.job_record(user: user, repository: repo, epic: middle, issue_number: 21, issue_title: "Pave")
      leaf_job = Factories.job_record(user: user, repository: repo, epic: leaf, issue_number: 22, issue_title: "Haul")
      JobDependency.create!(job: middle_job, depends_on_job: root_job, source: "manual", created_by_user: user)
      JobDependency.create!(job: leaf_job, depends_on_job: middle_job, source: "manual", created_by_user: user)

      get epic_path(root)

      expect(response.body).to include("Show all transitive dependencies")
      expect(response.body).to include("job_#{middle_job.id}")
      expect(response.body).not_to include("job_#{leaf_job.id}")

      get epic_path(root), params: { graph_depth: "transitive" }

      expect(response.body).to include("Show local dependencies")
      expect(response.body).to include("job_#{middle_job.id}")
      expect(response.body).to include("job_#{leaf_job.id}")
    end

    it "renders a drawer graph frame for Kanban cards" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, title: "Restore forum")
      Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 30, issue_title: "Set stones")

      get graph_epic_path(epic), params: { drawer: 1 }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('turbo-frame id="epic_graph_drawer_body"')
      expect(response.body).to include("Dependency graph")
      expect(response.body).to include("Show all transitive dependencies")
    end

    it "does not expose another user's Epic" do
      other = Factories.user
      epic = Factories.epic(user: other)
      sign_in_as(user)

      get epic_path(epic)

      expect(response).to have_http_status(:not_found)
    end
  end
end
