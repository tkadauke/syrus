require "rails_helper"

RSpec.describe "API: /api/v1/admin/epics", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) { admin; Factories.user }  # second user → not admin
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { non_admin.generate_api_token! }

  def auth(token) = { "Authorization" => "Bearer #{token}" }
  def parse_body  = JSON.parse(response.body)

  let(:repo)  { Factories.repository(user: admin, owner: "acme", name: "widgets") }
  let(:epic)  { Factories.epic(user: admin, repository: repo, title: "Launch", state: "ready") }

  describe "auth" do
    it "401s without an Authorization header" do
      get "/api/v1/admin/epics/#{epic.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it "403s when the token belongs to a non-admin user" do
      get "/api/v1/admin/epics/#{epic.id}", headers: auth(non_admin_token)
      expect(response).to have_http_status(:forbidden)
    end

    it "200s with an admin token" do
      get "/api/v1/admin/epics/#{epic.id}", headers: auth(admin_token)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /epics" do
    before { admin_token }

    it "creates an Epic for the target repository owner" do
      owner = Factories.user
      target_repo = Factories.repository(user: owner, owner: "acme", name: "api")

      expect {
        post "/api/v1/admin/epics",
             params: {
               epic: {
                 repo: "acme/api",
                 title: "Treat the API as a public road",
                 description: "Pave the path for external orchestrators.",
                 auto_approve_mode: "if_graders_pass",
                 epic_dependency_policy: "nonlinear"
               }
             },
             headers: auth(admin_token)
      }.to change(Epic, :count).by(1)

      expect(response).to have_http_status(:created)
      created = Epic.order(:created_at).last
      expect(created.user).to eq(owner)
      expect(created.repository).to eq(target_repo)
      expect(created.title).to eq("Treat the API as a public road")
      expect(created.description).to eq("Pave the path for external orchestrators.")
      expect(created.auto_approve_mode).to eq("if_graders_pass")
      expect(created.epic_dependency_policy).to eq("nonlinear")

      body = parse_body
      expect(body["message"]).to eq("Epic created.")
      expect(body.dig("epic", "id")).to eq(created.id)
      expect(body.dig("epic", "epic_dependency_policy")).to eq("nonlinear")
      expect(body.dig("epic", "resolved_epic_dependency_policy")).to eq("nonlinear")
      expect(body.dig("epic", "repository", "slug")).to eq("acme/api")
    end

    it "rejects invalid Epic create requests" do
      repo

      aggregate_failures do
        expect {
          post "/api/v1/admin/epics", params: { epic: { repository_id: repo.id, title: "" } }, headers: auth(admin_token)
        }.not_to change(Epic, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(parse_body.dig("error", "message")).to include("Title")

        expect {
          post "/api/v1/admin/epics", params: { epic: { repository: "missing/repo", title: "Lost" } }, headers: auth(admin_token)
        }.not_to change(Epic, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(parse_body.dig("error", "message")).to include("Repository not found")
      end
    end
  end

  describe "GET /epics (index)" do
    before do
      sign_in_as(admin)
      admin_token
      epic
      Factories.epic(user: admin, repository: repo, title: "Done epic", state: "done")
      other_repo = Factories.repository(user: admin, owner: "acme", name: "api")
      Factories.epic(user: admin, repository: other_repo, title: "Other-repo epic", state: "in_progress")
    end

    it "returns a compact list with count" do
      get "/api/v1/admin/epics", headers: auth(admin_token)

      body = parse_body
      expect(body["count"]).to eq(3)
      epic_payload = body["epics"].find { |e| e["title"] == "Launch" }
      expect(epic_payload).to include("id", "number", "state", "repository", "auto_approve_mode", "epic_dependency_policy", "resolved_epic_dependency_policy", "owner_user_id", "owner_status", "owner_user")
      expect(epic_payload["repository"]).to eq("acme/widgets")
    end

    it "filters by ?state=" do
      get "/api/v1/admin/epics", params: { state: "done" }, headers: auth(admin_token)
      titles = parse_body["epics"].map { |e| e["title"] }
      expect(titles).to contain_exactly("Done epic")
    end

    it "filters by ?repo=owner/name" do
      get "/api/v1/admin/epics", params: { repo: "acme/widgets" }, headers: auth(admin_token)
      slugs = parse_body["epics"].map { |e| e["repository"] }.uniq
      expect(slugs).to eq([ "acme/widgets" ])
    end

    it "filters by ?has_unfinished_children=true" do
      Factories.job_record(user: admin, repository: repo, epic: epic,
                           issue_number: 1, state: "queued")

      get "/api/v1/admin/epics", params: { has_unfinished_children: "true" }, headers: auth(admin_token)
      titles = parse_body["epics"].map { |e| e["title"] }
      expect(titles).to include("Launch")
      expect(titles).not_to include("Done epic")
    end

    it "filters by owner claim state relative to the API user" do
      other_owner = Factories.user
      mine = Factories.epic(user: admin, repository: repo, title: "Mine", owner_user: admin)
      other = Factories.epic(user: other_owner, repository: Factories.repository(user: other_owner), title: "Other-owned", owner_user: other_owner)
      unclaimed = Factories.epic(user: admin, repository: repo, title: "Unclaimed", owner_user: nil)

      get "/api/v1/admin/epics", params: { owner: "mine" }, headers: auth(admin_token)
      expect(parse_body["epics"].map { |e| e["id"] }).to include(mine.id)
      expect(parse_body["epics"].map { |e| e["id"] }).not_to include(other.id, unclaimed.id)
      expect(parse_body["epics"].find { |e| e["id"] == mine.id }).to include(
        "owner_status" => "mine",
        "owner_user" => include("id" => admin.id, "email_address" => admin.email_address)
      )

      get "/api/v1/admin/epics", params: { owner: "other_owned" }, headers: auth(admin_token)
      expect(parse_body["epics"].map { |e| e["id"] }).to include(other.id)
      expect(parse_body["epics"].map { |e| e["id"] }).not_to include(mine.id, unclaimed.id)
      expect(parse_body["epics"].find { |e| e["id"] == other.id }).to include("owner_status" => "other_owned")

      get "/api/v1/admin/epics", params: { owner: "unclaimed" }, headers: auth(admin_token)
      expect(parse_body["epics"].map { |e| e["id"] }).to include(unclaimed.id)
      expect(parse_body["epics"].map { |e| e["id"] }).not_to include(mine.id, other.id)
      expect(parse_body["epics"].find { |e| e["id"] == unclaimed.id }).to include(
        "owner_status" => "unclaimed",
        "owner_user" => nil
      )
    end
  end

  describe "GET /epics/:id (show)" do
    before { sign_in_as(admin); admin_token }

    it "returns the full payload with child jobs + dependency edges" do
      prereq = Factories.epic(user: admin, repository: repo, title: "Prereq")
      EpicDependency.create!(epic: epic, depends_on_epic: prereq)
      child_a = Factories.job_record(user: admin, repository: repo, epic: epic,
                                     issue_number: 10, state: "queued")
      child_b = Factories.job_record(user: admin, repository: repo, epic: epic,
                                     issue_number: 11, state: "closed",
                                     closure_reason: "pr_merged", finished_at: Time.current)

      get "/api/v1/admin/epics/#{epic.id}", headers: auth(admin_token)

      body = parse_body
      expect(body).to include(
        "id" => epic.id,
        "state" => "ready",
        "title" => "Launch",
        "owner_status" => "unclaimed",
        "owner_user" => nil,
        "epic_dependency_policy" => "inherit",
        "resolved_epic_dependency_policy" => "linear",
        "complete" => false,
        "ready_to_start" => false  # depends on prereq Epic that isn't done
      )
      expect(body["repository"]).to include("slug" => "acme/widgets")
      expect(body["depends_on_epic_ids"]).to eq([ prereq.id ])
      expect(body["jobs"].map { |j| j["id"] }).to contain_exactly(child_a.id, child_b.id)
      child_a_payload = body["jobs"].find { |j| j["id"] == child_a.id }
      expect(child_a_payload).to include("state" => "queued", "kind" => "issue", "repository" => "acme/widgets")
    end

    it "404s with a JSON error envelope for an unknown id" do
      get "/api/v1/admin/epics/9999999", headers: auth(admin_token)
      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("not_found")
    end
  end
end
