require "rails_helper"

RSpec.describe "API: /api/v1/app/epics", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/epics/new"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "returns the new epic form payload with the user's repositories" do
    sign_in_as(user)
    repository
    Factories.repository(user: Factories.user, owner: "other", name: "private")

    get "/api/v1/app/epics/new"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("epic", "id")).to be_nil
    expect(body["repositories"]).to contain_exactly(include("id" => repository.id, "slug" => "acme/widgets"))
    expect(body.to_s).not_to include("other/private")
    expect(body["dashboard_epics_path"]).to eq(dashboard_epics_path)
  end

  it "returns the edit epic form payload" do
    sign_in_as(user)
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "Raise the forum",
      description: "Install tasteful columns.",
      github_issue_url: "https://github.com/acme/widgets/issues/12"
    )

    get "/api/v1/app/epics/#{epic.id}/edit"

    expect(response).to have_http_status(:ok)
    expect(parse_body["epic"]).to include(
      "id" => epic.id,
      "title" => "Raise the forum",
      "description" => "Install tasteful columns.",
      "repository_id" => repository.id,
      "github_issue_url" => "https://github.com/acme/widgets/issues/12",
      "epic_path" => epic_path(epic)
    )
  end

  it "returns the Epic detail payload with child Jobs and dependency graph data" do
    sign_in_as(user)
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "Raise the forum",
      description: "Build **columns**.",
      state: "ready"
    )
    blocker = Factories.epic(user: user, repository: repository, title: "Deliver marble", state: "done")
    EpicDependency.create!(epic: epic, depends_on_epic: blocker, derived: false)
    job = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 12,
      issue_title: "Survey forum",
      state: "closed",
      closure_reason: "pr_merged"
    )

    get "/api/v1/app/epics/#{epic.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("epic", "display_number")).to eq(epic.display_number)
    expect(body.dig("epic", "description")).to eq("Build **columns**.")
    expect(body.dig("epic", "owner")).to be_nil
    expect(body.dig("epic", "owned_by_current_user")).to eq(false)
    expect(body.dig("epic", "claimable")).to eq(true)
    expect(body.dig("epic", "repository")).to include("slug" => "acme/widgets", "repository_path" => repository_path(repository))
    expect(body["summary"]).to include(
      "done_jobs_count" => 1,
      "total_jobs_count" => 1,
      "dependency_edge_count" => 1,
      "blocked" => false
    )
    expect(body["state_transitions"]).to contain_exactly(
      include("label" => "Move to backlog", "target_state" => "backlog"),
      include("label" => "Start", "target_state" => "in_progress"),
      include("label" => "Archive", "target_state" => "archived", "confirm" => "Archive this Epic?")
    )
    expect(body["graph"]).to include(
      "empty" => false,
      "node_count" => 2,
      "epic_dependency_count" => 1,
      "job_blocker_count" => 0,
      "initially_open" => true
    )
    expect(body.dig("graph", "definition")).to include("flowchart LR", "Deliver marble")
    expect(body["jobs"]).to contain_exactly(include(
      "id" => job.id,
      "label" => "#12",
      "title" => "Survey forum",
      "path" => job_path(job),
      "state" => "closed",
      "repository_slug" => "acme/widgets"
    ))
    expect(body["paths"]).to include(
      "dashboard_epics_path" => dashboard_epics_path,
      "edit_epic_path" => edit_epic_path(epic),
      "app_state_path" => "/api/v1/app/epics/#{epic.id}/state",
      "app_archive_path" => "/api/v1/app/epics/#{epic.id}/archive",
      "app_claim_path" => "/api/v1/app/epics/#{epic.id}/claim",
      "app_unclaim_path" => "/api/v1/app/epics/#{epic.id}/unclaim",
      "app_reassign_path" => "/api/v1/app/epics/#{epic.id}/reassign"
    )
  end

  it "claims and unclaims ready Epics through the app API" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "ready")

    patch "/api/v1/app/epics/#{epic.id}/claim"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Epic claimed.")
    expect(parse_body.dig("epic", "owner")).to include("id" => user.id, "email_address" => user.email_address)
    expect(epic.reload.owner).to eq(user)
    expect(epic.claimed_at).to be_present

    patch "/api/v1/app/epics/#{epic.id}/unclaim"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Epic unclaimed.")
    expect(parse_body.dig("epic", "owner")).to be_nil
    expect(epic.reload.owner).to be_nil
    expect(epic.claimed_at).to be_nil
  end

  it "reassigns ready Epics through an explicit app API action" do
    sign_in_as(user)
    first_owner = Factories.user(email_address: "first@example.com")
    next_owner = Factories.user(email_address: "next@example.com")
    epic = Factories.epic(user: user, repository: repository, state: "ready", owner: first_owner, claimed_at: 1.hour.ago)

    patch "/api/v1/app/epics/#{epic.id}/reassign", params: { owner_id: next_owner.id }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Epic reassigned.")
    expect(parse_body.dig("epic", "owner")).to include("id" => next_owner.id, "email_address" => next_owner.email_address)
    expect(epic.reload.owner).to eq(next_owner)
    expect(epic.claimed_at).to be_present
  end

  it "advances Epic state through the app API and returns a refreshed detail payload" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "ready")
    job = Factories.job_record(user: user, repository: repository, epic: epic, state: "blocked_by_epic")

    expect {
      patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "in_progress" }
    }.to change(Run, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Epic updated.")
    expect(parse_body.dig("epic", "state")).to eq("in_progress")
    expect(parse_body.dig("epic", "owner")).to include("id" => user.id)
    expect(epic.reload).to be_in_progress
    expect(epic.owner).to eq(user)
    expect(job.reload).to be_queued
  end

  it "does not take over an already-owned Epic when moving to in-progress" do
    sign_in_as(user)
    owner = Factories.user(email_address: "owner@example.com")
    epic = Factories.epic(user: user, repository: repository, state: "ready", owner: owner, claimed_at: 1.hour.ago)
    Factories.job_record(user: user, repository: repository, epic: epic, state: "blocked_by_epic")

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "in_progress" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("transition_not_allowed")
    expect(epic.reload.owner).to eq(owner)
    expect(epic).to be_ready
  end

  it "moves ready Epics back to backlog through the app API" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "ready")

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "backlog" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("epic", "state")).to eq("backlog")
    expect(epic.reload).to be_backlog
  end

  it "moves backlog Epics with child Jobs to ready through the app API" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "ready")
    Factories.job_record(user: user, repository: repository, epic: epic, state: "blocked_by_epic")
    epic.move_to_backlog!

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "ready" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("epic", "state")).to eq("ready")
    expect(epic.reload).to be_ready
  end

  it "rejects unavailable and unknown app API Epic state transitions" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "backlog")

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "ready" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("transition_not_allowed")
    expect(epic.reload).to be_backlog

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "done" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("transition_not_allowed")
    expect(epic.reload).to be_backlog

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "defenestrated" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("unknown_state")
    expect(epic.reload).to be_backlog
  end

  it "archives an Epic through the app API" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "ready")

    patch "/api/v1/app/epics/#{epic.id}/archive"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Epic archived.")
    expect(parse_body.dig("epic", "state")).to eq("archived")
    expect(epic.reload).to be_archived
  end

  it "creates an epic and returns its redirect path" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/epics", params: {
        epic: {
          title: "Raise the forum",
          description: "Install tasteful columns.",
          repository_id: repository.id,
          github_issue_url: "https://github.com/acme/widgets/issues/12"
        }
      }
    }.to change { user.epics.count }.by(1)

    expect(response).to have_http_status(:created)
    epic = user.epics.order(:id).last
    expect(epic).to have_attributes(
      title: "Raise the forum",
      description: "Install tasteful columns.",
      repository_id: repository.id,
      github_issue_url: "https://github.com/acme/widgets/issues/12"
    )
    expect(parse_body).to include(
      "message" => "Epic created.",
      "redirect_to" => epic_path(epic)
    )
  end

  it "returns validation errors without creating an epic" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/epics", params: {
        epic: {
          title: "",
          repository_id: repository.id
        }
      }
    }.not_to change { user.epics.count }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("Title can't be blank")
  end

  it "updates an epic" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, title: "Raise the forum")
    other_repo = Factories.repository(user: user, owner: "acme", name: "marble")

    patch "/api/v1/app/epics/#{epic.id}", params: {
      epic: {
        title: "Raise the basilica",
        description: "Install louder columns.",
        repository_id: other_repo.id,
        github_issue_url: "https://github.com/acme/marble/issues/7"
      }
    }

    expect(response).to have_http_status(:ok)
    expect(epic.reload).to have_attributes(
      title: "Raise the basilica",
      description: "Install louder columns.",
      repository_id: other_repo.id,
      github_issue_url: "https://github.com/acme/marble/issues/7"
    )
    expect(parse_body).to include("message" => "Epic updated.", "redirect_to" => epic_path(epic))
  end

  it "does not expose another user's epic" do
    sign_in_as(user)
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    epic = Factories.epic(user: other_user, repository: other_repo, title: "Private aqueduct")

    get "/api/v1/app/epics/#{epic.id}/edit"
    expect(response).to have_http_status(:not_found)

    get "/api/v1/app/epics/#{epic.id}"
    expect(response).to have_http_status(:not_found)

    patch "/api/v1/app/epics/#{epic.id}", params: { epic: { title: "Rename it", repository_id: repository.id } }
    expect(response).to have_http_status(:not_found)
    expect(epic.reload.title).to eq("Private aqueduct")

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "ready" }
    expect(response).to have_http_status(:not_found)
  end
end
