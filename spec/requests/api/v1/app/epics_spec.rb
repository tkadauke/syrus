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

  it "lists epics for bearer-token CLI clients with repository scoping" do
    user.update!(api_token: "syrus_cli_token")
    epic = Factories.epic(user: user, repository: repository, title: "Raise the forum", state: "in_progress")
    Factories.job_record(user: user, repository: repository, epic: epic, state: "closed", closure_reason: "pr_merged")
    Factories.job_record(user: user, repository: repository, epic: epic, state: "open")
    other_user = Factories.user
    Factories.epic(user: other_user, repository: Factories.repository(user: other_user, owner: "other", name: "repo"), title: "Private")

    get "/api/v1/app/epics", params: { repo: "acme/widgets" },
      headers: { "Authorization" => "Bearer syrus_cli_token" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["epics"]).to contain_exactly(include(
      "id" => epic.id,
      "title" => "Raise the forum",
      "repository_slug" => "acme/widgets",
      "done_jobs_count" => 1,
      "total_jobs_count" => 2
    ))
    expect(parse_body.to_s).not_to include("Private")
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
      state: "ready",
      owner_user: user
    )
    blocker = Factories.epic(user: user, repository: repository, title: "Deliver marble", state: "done")
    EpicDependency.create!(epic: epic, depends_on_epic: blocker, derived: false)
    job = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 12,
      issue_title: "Survey forum",
      branch_name: "syrus/issue-12-#{epic.id}",
      state: "closed",
      closure_reason: "pr_merged"
    )
    dependent = Factories.job_record(user: user, repository: repository, epic: epic)
    dependent.dependencies.create!(depends_on_job: job, source: "manual", created_by_user: user)

    get "/api/v1/app/epics/#{epic.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("epic", "display_number")).to eq(epic.display_number)
    expect(body.dig("epic", "description")).to eq("Build **columns**.")
    expect(body.dig("epic", "stuck")).to eq(false)
    expect(body.dig("epic", "owner")).to be_nil
    expect(body.dig("epic", "owned_by_current_user")).to eq(true)
    expect(body.dig("epic", "claimable")).to eq(true)
    expect(body["epic"]).to include(
      "owner_user_id" => user.id,
      "owner_status" => "mine",
      "owner_user" => include("id" => user.id, "email_address" => user.email_address)
    )
    expect(body.dig("epic", "repository")).to include("slug" => "acme/widgets", "repository_path" => repository_path(repository))
    expect(body["summary"]).to include(
      "done_jobs_count" => 1,
      "total_jobs_count" => 2,
      "dependency_edge_count" => 1,
      "blocked" => false,
      "blocked_reason" => nil
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
    expect(body["dependencies"]).to contain_exactly(include(
      "epic_id" => blocker.id,
      "title" => "Deliver marble",
      "state" => "done",
      "url" => epic_path(blocker)
    ))
    expect(body["dependents"]).to eq([])
    expect(body["jobs"]).to include(include(
      "id" => job.id,
      "label" => "#12",
      "title" => "Survey forum",
      "path" => job_path(job),
      "state" => "closed",
      "repository_slug" => "acme/widgets",
      "branch_name" => "syrus/issue-12-#{epic.id}",
      "depends_on_job_ids" => []
    ))
    expect(body["jobs"]).to include(include(
      "id" => dependent.id,
      "branch_name" => dependent.branch_name.to_s,
      "depends_on_job_ids" => [ job.id ]
    ))
    expect(body["paths"]).to include(
      "dashboard_epics_path" => dashboard_epics_path,
      "edit_epic_path" => edit_epic_path(epic),
      "app_state_path" => "/api/v1/app/epics/#{epic.id}/state",
      "app_archive_path" => "/api/v1/app/epics/#{epic.id}/archive",
      "app_claim_path" => "/api/v1/app/epics/#{epic.id}/claim",
      "app_unclaim_path" => "/api/v1/app/epics/#{epic.id}/unclaim",
      "app_reassign_path" => "/api/v1/app/epics/#{epic.id}/reassign",
      "app_dependencies_path" => "/api/v1/app/epics/#{epic.id}/dependencies"
    )
  end

  it "includes stuck status in the Epic detail payload" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, title: "Stalled forum", state: "in_progress")
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 12,
      issue_title: "Cancelled child",
      state: "closed",
      closure_reason: "cancelled"
    )

    get "/api/v1/app/epics/#{epic.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("epic", "stuck")).to eq(true)
  end

  it "offers Mark as done for in-progress Epics whose child Jobs are all closed" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, title: "Stalled forum", state: "in_progress")
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 12,
      issue_title: "Cancelled child",
      state: "closed",
      closure_reason: "cancelled"
    )

    get "/api/v1/app/epics/#{epic.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["state_transitions"]).to include(
      include("label" => "Mark as done", "target_state" => "done")
    )
  end

  it "surfaces Job dependency blocked reasons on the Epic detail payload" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "ready")
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 8, state: "queued")
    EpicDependency.create!(epic: epic, depends_on_job: prerequisite)

    get "/api/v1/app/epics/#{epic.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["summary"]).to include(
      "blocked" => true,
      "blocked_reason" => "waiting for Job #8 to merge"
    )
    expect(parse_body["dependencies"]).to eq([])
  end

  it "creates an Epic dependency and returns the updated detail payload" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, title: "Chat search UI")
    blocker = Factories.epic(user: user, repository: repository, title: "Chat FTS5 infrastructure", state: "in_progress")

    expect {
      post "/api/v1/app/epics/#{epic.id}/dependencies", params: { depends_on_epic_id: blocker.id }, as: :json
    }.to change(EpicDependency, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Dependency added.")
    expect(parse_body["dependencies"]).to contain_exactly(include(
      "epic_id" => blocker.id,
      "title" => "Chat FTS5 infrastructure",
      "state" => "in_progress",
      "url" => epic_path(blocker)
    ))
  end

  it "rejects Epic dependencies that would create a cycle" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, title: "Chat search UI")
    blocker = Factories.epic(user: user, repository: repository, title: "Chat FTS5 infrastructure")
    EpicDependency.create!(epic: blocker, depends_on_epic: epic)

    expect {
      post "/api/v1/app/epics/#{epic.id}/dependencies", params: { depends_on_epic_id: blocker.id }, as: :json
    }.not_to change(EpicDependency, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("would create a cycle")
  end

  it "removes an Epic dependency and treats double-delete as success" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, title: "Chat search UI")
    blocker = Factories.epic(user: user, repository: repository, title: "Chat FTS5 infrastructure")
    EpicDependency.create!(epic: epic, depends_on_epic: blocker)

    expect {
      delete "/api/v1/app/epics/#{epic.id}/dependencies/#{blocker.id}", as: :json
    }.to change(EpicDependency, :count).by(-1)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Dependency removed.")
    expect(parse_body["dependencies"]).to eq([])

    expect {
      delete "/api/v1/app/epics/#{epic.id}/dependencies/#{blocker.id}", as: :json
    }.not_to change(EpicDependency, :count)

    expect(response).to have_http_status(:ok)
    expect(parse_body["dependencies"]).to eq([])
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

  it "marks unclaimed Epics in app payloads" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, owner_user: nil)

    get "/api/v1/app/epics/#{epic.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body["epic"]).to include(
      "owner_user_id" => nil,
      "owner_status" => "unclaimed",
      "owner_user" => nil
    )
  end

  it "claims an unclaimed Epic atomically through the app API" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, owner_user: nil)
    unowned_child = Factories.job_record(user: user, repository: repository, epic: epic, owner_user: nil)
    existing_owner = Factories.user(email_address: "already-owned@example.com")
    owned_child = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 43, owner_user: existing_owner)

    patch "/api/v1/app/epics/#{epic.id}/claim"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Epic claimed.")
    expect(parse_body["epic"]).to include(
      "owner_user_id" => user.id,
      "owner_status" => "mine",
      "owner_user" => include("id" => user.id, "email_address" => user.email_address)
    )
    expect(epic.reload.owner_user).to eq(user)
    expect(unowned_child.reload.owner_user).to eq(user)
    expect(owned_child.reload.owner_user).to eq(existing_owner)
    expect(parse_body["jobs"]).to include(
      include("id" => unowned_child.id, "owner_user_id" => user.id, "owner_user" => include("email_address" => user.email_address)),
      include("id" => owned_child.id, "owner_user_id" => existing_owner.id, "owner_user" => include("email_address" => "already-owned@example.com"))
    )
  end

  it "rejects claim races instead of overwriting the current owner" do
    sign_in_as(user)
    current_owner = Factories.user(email_address: "owner@example.com")
    epic = Factories.epic(user: user, repository: repository, owner_user: current_owner)
    unowned_child = Factories.job_record(user: user, repository: repository, epic: epic, owner_user: nil)

    patch "/api/v1/app/epics/#{epic.id}/claim"

    expect(response).to have_http_status(:conflict)
    expect(parse_body.dig("error", "code")).to eq("epic_already_owned")
    expect(parse_body.dig("error", "message")).to include("owner@example.com")
    expect(epic.reload.owner_user).to eq(current_owner)
    expect(unowned_child.reload.owner_user).to be_nil
  end

  it "returns a clear error when claiming an Epic already claimed by the current user" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, owner_user: user)

    patch "/api/v1/app/epics/#{epic.id}/claim"

    expect(response).to have_http_status(:conflict)
    expect(parse_body.dig("error", "code")).to eq("epic_already_owned")
    expect(parse_body.dig("error", "message")).to eq("Epic is already claimed by you.")
    expect(epic.reload.owner_user).to eq(user)
  end

  it "unclaims an Epic owned by the current user" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, owner_user: user)

    patch "/api/v1/app/epics/#{epic.id}/unclaim"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Epic unclaimed.")
    expect(parse_body["epic"]).to include(
      "owner_user_id" => nil,
      "owner_status" => "unclaimed",
      "owner_user" => nil
    )
    expect(epic.reload.owner_user).to be_nil
  end

  it "does not let a non-owner unclaim someone else's Epic" do
    admin = Factories.user(admin: true)
    regular = Factories.user(admin: false)
    regular_repo = Factories.repository(user: regular, owner: "acme", name: "tiles")
    owner = Factories.user(email_address: "owner@example.com")
    epic = Factories.epic(user: regular, repository: regular_repo, owner_user: owner)
    sign_in_as(regular)

    patch "/api/v1/app/epics/#{epic.id}/unclaim"

    expect(admin).to be_admin
    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
    expect(epic.reload.owner_user).to eq(owner)
  end

  it "lets an admin unclaim an Epic owned by another user" do
    admin = Factories.user(admin: true)
    admin_repo = Factories.repository(user: admin, owner: "acme", name: "roads")
    owner = Factories.user(email_address: "owner@example.com")
    epic = Factories.epic(user: admin, repository: admin_repo, owner_user: owner)
    sign_in_as(admin)

    patch "/api/v1/app/epics/#{epic.id}/unclaim"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Epic unclaimed.")
    expect(epic.reload.owner_user).to be_nil
  end

  it "reassigns Epic ownership for admins" do
    admin = Factories.user(admin: true)
    admin_repo = Factories.repository(user: admin, owner: "acme", name: "forums")
    new_owner = Factories.user(email_address: "assignee@example.com")
    epic = Factories.epic(user: admin, repository: admin_repo, owner_user: nil)
    unowned_child = Factories.job_record(user: admin, repository: admin_repo, epic: epic, owner_user: nil)
    previous_child_owner = Factories.user(email_address: "previous-child@example.com")
    owned_child = Factories.job_record(user: admin, repository: admin_repo, epic: epic, issue_number: 43, owner_user: previous_child_owner)
    sign_in_as(admin)

    patch "/api/v1/app/epics/#{epic.id}/reassign", params: { owner_user_id: new_owner.id }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include("message" => "Epic reassigned.")
    expect(parse_body["epic"]).to include(
      "owner_user_id" => new_owner.id,
      "owner_status" => "other_owned",
      "owner_user" => include("id" => new_owner.id, "email_address" => "assignee@example.com")
    )
    expect(epic.reload.owner_user).to eq(new_owner)
    expect(unowned_child.reload.owner_user).to eq(new_owner)
    expect(owned_child.reload.owner_user).to eq(new_owner)
  end

  it "requires admin access to reassign Epic ownership" do
    Factories.user(admin: true)
    regular = Factories.user(admin: false)
    regular_repo = Factories.repository(user: regular, owner: "acme", name: "baths")
    new_owner = Factories.user(email_address: "assignee@example.com")
    epic = Factories.epic(user: regular, repository: regular_repo, owner_user: regular)
    sign_in_as(regular)

    patch "/api/v1/app/epics/#{epic.id}/reassign", params: { owner_user_id: new_owner.id }

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
    expect(epic.reload.owner_user).to eq(regular)
  end

  it "rejects reassigning to an unknown or current owner" do
    admin = Factories.user(admin: true)
    admin_repo = Factories.repository(user: admin, owner: "acme", name: "arches")
    owner = Factories.user(email_address: "owner@example.com")
    epic = Factories.epic(user: admin, repository: admin_repo, owner_user: owner)
    sign_in_as(admin)

    patch "/api/v1/app/epics/#{epic.id}/reassign", params: { owner_user_id: 999_999 }

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("owner_not_found")
    expect(epic.reload.owner_user).to eq(owner)

    patch "/api/v1/app/epics/#{epic.id}/reassign", params: { owner_user_id: owner.id }

    expect(response).to have_http_status(:conflict)
    expect(parse_body.dig("error", "code")).to eq("epic_already_owned")
    expect(parse_body.dig("error", "message")).to include("owner@example.com")
    expect(epic.reload.owner_user).to eq(owner)
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

  it "force-starts a backlog Epic with override (the chat Start action)" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "backlog")
    job = Factories.job_record(user: user, repository: repository, epic: epic, state: "blocked_by_epic")

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "in_progress", override: true }

    expect(response).to have_http_status(:ok)
    expect(epic.reload).to be_in_progress
    expect(job.reload).not_to be_blocked_by_epic
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

  it "claims an unclaimed Epic for the current user when moving it to in-progress" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "ready", owner_user: nil)
    unowned_child = Factories.job_record(user: user, repository: repository, epic: epic, owner_user: nil)
    existing_owner = Factories.user(email_address: "already-owned@example.com")
    owned_child = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 43, owner_user: existing_owner)

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "in_progress" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("epic", "state")).to eq("in_progress")
    expect(parse_body["epic"]).to include(
      "owner_user_id" => user.id,
      "owner_status" => "mine",
      "owner_user" => include("id" => user.id, "email_address" => user.email_address)
    )
    expect(epic.reload.owner_user).to eq(user)
    expect(unowned_child.reload.owner_user).to eq(user)
    expect(owned_child.reload.owner_user).to eq(existing_owner)
    expect(parse_body["jobs"]).to include(
      include("id" => unowned_child.id, "owner_user_id" => user.id, "owner_user" => include("email_address" => user.email_address)),
      include("id" => owned_child.id, "owner_user_id" => existing_owner.id, "owner_user" => include("email_address" => "already-owned@example.com"))
    )
  end

  it "does not take over an already-owned Epic when moving it to in-progress" do
    sign_in_as(user)
    owner = Factories.user(email_address: "owner@example.com")
    epic = Factories.epic(user: user, repository: repository, state: "ready", owner_user: owner)
    unowned_child = Factories.job_record(user: user, repository: repository, epic: epic, owner_user: nil)

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "in_progress" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("epic", "state")).to eq("in_progress")
    expect(parse_body["epic"]).to include(
      "owner_user_id" => owner.id,
      "owner_status" => "other_owned",
      "owner_user" => include("id" => owner.id, "email_address" => "owner@example.com")
    )
    expect(epic.reload.owner_user).to eq(owner)
    expect(unowned_child.reload.owner_user).to be_nil
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

  it "marks an in-progress Epic as done when all child Jobs are closed" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 34,
      state: "closed",
      closure_reason: "cancelled"
    )

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "done" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("epic", "state")).to eq("done")
    expect(epic.reload).to be_done
    expect(epic.done_at).to be_present
  end

  it "does not mark an in-progress Epic as done while child Jobs remain open" do
    sign_in_as(user)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 34, state: "closed", closure_reason: "cancelled")
    Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 35, state: "queued")

    patch "/api/v1/app/epics/#{epic.id}/state", params: { target_state: "done" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("transition_not_allowed")
    expect(epic.reload).to be_in_progress
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

    patch "/api/v1/app/epics/#{epic.id}/claim"
    expect(response).to have_http_status(:not_found)

    patch "/api/v1/app/epics/#{epic.id}/unclaim"
    expect(response).to have_http_status(:not_found)

    patch "/api/v1/app/epics/#{epic.id}/reassign", params: { owner_user_id: user.id }
    expect(response).to have_http_status(:not_found)
  end
end
