require "rails_helper"

RSpec.describe "Filter FK options", type: :request do
  describe "GET /filters/fk_options" do
    it "returns 401 when unauthenticated" do
      get "/filters/fk_options", params: { field: "job_id" }

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to eq("error" => "unauthorized")
    end

    it "returns 400 for unknown fields" do
      user = Factories.user
      sign_in_as(user)

      get "/filters/fk_options", params: { field: "user_id" }

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to eq("error" => "unknown field")
    end

    it "scopes job options to the current user" do
      user = Factories.user
      repo = Factories.repository(user:)
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      own = Factories.job_record(user:, repository: repo, issue_number: 42, issue_title: "Find me")
      Factories.job_record(user: other_user, repository: other_repo, issue_number: 43, issue_title: "Find me elsewhere")
      sign_in_as(user)

      get "/filters/fk_options", params: { field: "job_id", q: "Find me" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq([
        { "value" => own.id, "label" => "#42 Find me" }
      ])
    end

    it "searches jobs by title, exact issue number, and branch name" do
      user = Factories.user
      repo = Factories.repository(user:)
      by_title = Factories.job_record(user:, repository: repo, issue_number: 10, issue_title: "Add typeahead")
      by_number = Factories.job_record(user:, repository: repo, issue_number: 99, issue_title: "Unrelated")
      by_branch = Factories.job_record(user:, repository: repo, issue_number: 11, issue_title: "Branch match", branch_name: "syrus/fk-options")
      Factories.job_record(user:, repository: repo, issue_number: 100, issue_title: "99 bottles")
      sign_in_as(user)

      get "/filters/fk_options", params: { field: "job_id", q: "typeahead" }
      expect(JSON.parse(response.body).map { |row| row["value"] }).to eq([ by_title.id ])

      get "/filters/fk_options", params: { field: "job_id", q: "99" }
      expect(JSON.parse(response.body).map { |row| row["value"] }).to include(by_number.id)

      get "/filters/fk_options", params: { field: "job_id", q: "fk-options" }
      expect(JSON.parse(response.body).map { |row| row["value"] }).to eq([ by_branch.id ])
    end

    it "resolves labels for explicit ids in bulk" do
      user = Factories.user
      repo = Factories.repository(user:)
      old = Factories.job_record(user:, repository: repo, issue_number: 7, issue_title: "Ancient task", created_at: 3.years.ago)
      recent = Factories.job_record(user:, repository: repo, issue_number: 8, issue_title: "Recent task")
      sign_in_as(user)

      get "/filters/fk_options", params: { field: "job_id", ids: [ old.id, recent.id ] }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to contain_exactly(
        { "value" => old.id, "label" => "#7 Ancient task" },
        { "value" => recent.id, "label" => "#8 Recent task" }
      )
    end

    it "caps search responses at 50 results" do
      user = Factories.user
      repo = Factories.repository(user:)
      60.times do |i|
        Factories.job_record(user:, repository: repo, issue_number: i + 1, issue_title: "Bulk searchable #{i}")
      end
      sign_in_as(user)

      get "/filters/fk_options", params: { field: "job_id", q: "Bulk searchable" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).size).to eq(50)
    end

    it "searches repositories, epics, tags, and hostnames through their label columns" do
      user = Factories.user
      repo = Factories.repository(user:, owner: "acme", name: "widgets")
      epic = Factories.epic(user:, repository: repo, title: "Typeahead migration")
      tag = Factories.tag(user:, name: "backend")
      SpawnedProcess.create!(
        kind: "agent",
        command: "claude --print",
        hostname: "syrus-worker-alpha",
        started_at: 1.minute.ago
      )
      sign_in_as(user)

      get "/filters/fk_options", params: { field: "repository_id", q: "widg" }
      expect(JSON.parse(response.body)).to eq([{ "value" => repo.id, "label" => "acme/widgets" }])

      get "/filters/fk_options", params: { field: "epic_id", q: "migration" }
      expect(JSON.parse(response.body)).to eq([{ "value" => epic.id, "label" => "EPIC-#{epic.number} Typeahead migration" }])

      get "/filters/fk_options", params: { field: "tags", q: "back" }
      expect(JSON.parse(response.body)).to eq([{ "value" => tag.id, "label" => "backend" }])

      get "/filters/fk_options", params: { field: "hostname", q: "alpha" }
      expect(JSON.parse(response.body)).to eq([{ "value" => "syrus-worker-alpha", "label" => "syrus-worker-alpha" }])
    end
  end
end
