require "rails_helper"

RSpec.describe "App API dashboard commands", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  def lane_item_ids(body, key)
    body.fetch("lanes").find { |lane| lane.fetch("key") == key }.fetch("items").map { |item| item.fetch("id") }
  end

  def finish_initial_work(job, provider: "claude")
    job.initial_run.update!(
      state: "succeeded",
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago,
      agent_provider: provider
    )
    job.latest_workflow.update!(state: "succeeded", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
  end

  describe "GET /api/v1/app/dashboard" do
    it "returns a subject-aware dashboard read payload for the current user" do
      user.update_dashboard_sort!(subject: "job", column: "title", direction: "asc")
      tag = Factories.tag(user: user, name: "aqueduct", color: "blue")
      epic = Factories.epic(user: user, repository: repo, title: "Raise the forum")
      first = Factories.job_record(repository: repo, epic: epic, issue_number: 1, issue_title: "Build aqueduct", state: "queued", pr_number: 17, owner_user: user)
      second = Factories.job_record(repository: repo, issue_number: 2, issue_title: "Chart forum", state: "running", owner_user: user)
      Workflow.create!(job: second, trigger_kind: "rebase", state: "running")
      first.tags << tag
      archived_repo = Factories.repository(user: user, owner: "acme", name: "archived", archived_at: Time.current)
      archived_job = Factories.job_record(repository: archived_repo, issue_number: 3, issue_title: "Hide archive", state: "queued")
      other_repo = Factories.repository(user: Factories.user, owner: "globex", name: "private")
      other_job = Factories.job_record(repository: other_repo, issue_number: 4, issue_title: "Hide private", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "kanban" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body).to include(
        "subject" => "job",
        "view" => "kanban",
        "page" => 1,
        "per_page" => 25,
        "total" => 2
      )
      expect(body.dig("counts", "jobs")).to eq(2)
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ first.id, second.id ])
      expect(body["items"].first).to include(
        "type" => "job",
        "title" => "Build aqueduct",
        "state" => "queued",
        "latest_workflow_trigger_kind" => nil,
        "latest_workflow_state" => "queued",
        "total_cost_usd" => nil,
        "workflows_count" => 0,
        "approved_at" => nil,
        "dependencies_overridden_at" => nil,
        "issue_url" => "https://github.com/acme/widgets/issues/1",
        "pr_url" => "https://github.com/acme/widgets/pull/17",
        "repository" => include("slug" => "acme/widgets"),
        "epic" => {
          "id" => epic.id,
          "number" => epic.number,
          "display_number" => epic.display_number,
          "path" => epic_path(epic)
        },
        "tags" => [ include("name" => "aqueduct", "color" => "blue") ],
        "paths" => include("job_path" => job_path(first), "source_path" => source_job_path(first))
      )
      expect(body["items"].find { |item| item.fetch("id") == second.id }).to include(
        "latest_workflow_trigger_kind" => "rebase",
        "latest_workflow_state" => "running"
      )
      expect(body["items"].map { |item| item.fetch("id") }).not_to include(archived_job.id, other_job.id)
      expect(body.dig("preferences", "sort")).to include("column" => "title", "direction" => "asc")
      expect(body["controls"]).to include(
        "views" => %w[list kanban],
        "sort_columns" => %w[title state repository created_at started_at],
        "sort_directions" => %w[asc desc],
        "columns" => {
          "required" => [
            { "key" => "checkbox", "title" => "Checkbox" },
            { "key" => "issue", "title" => "Issue" }
          ],
          "optional" => include(
            { "key" => "state", "title" => "State" },
            { "key" => "repository", "title" => "Repository" },
            { "key" => "workflows_count", "title" => "Workflows count" }
          )
        },
        "kanban_lanes" => [
          { "key" => "blocked", "title" => "Blocked" },
          { "key" => "queued", "title" => "Queued" },
          { "key" => "running", "title" => "Running" },
          { "key" => "succeeded", "title" => "Succeeded" },
          { "key" => "landing", "title" => "Landing" },
          { "key" => "failed", "title" => "Failed" }
        ]
      )
      expect(body.dig("controls", "filter_schema")).to include(
        include("field" => "state", "label" => "State", "values" => include(include("value" => "open", "label" => "Any open"))),
        include("field" => "repository_id", "label" => "Repository", "bucket" => "fk", "typeahead" => true)
      )
      expect(body["landing_queue"]).to eq(
        "visible" => false,
        "paused" => false,
        "toggle_path" => "/api/v1/app/dashboard/landing_pause"
      )
      expect(body["kanban_limit"]).to eq(100)
      expect(body["lanes"]).to include(
        include("key" => "queued", "title" => "Queued", "items" => include(include("id" => first.id, "title" => "Build aqueduct"))),
        include("key" => "running", "title" => "Running", "items" => include(include("id" => second.id, "title" => "Chart forum")))
      )
      expect(body.dig("paths", "dashboard_jobs_path")).to eq(dashboard_jobs_path)
      expect(body.dig("paths", "new_epic_path")).to eq(new_epic_path)
      expect(body.dig("paths", "new_job_path")).to eq(new_job_path)
      expect(user.reload.dashboard_preferences).to include("last_subject" => "job", "last_view" => "kanban")
    end

    it "keeps running jobs in the running Kanban lane even when blocked diagnostics are visible" do
      user.update_dashboard_kanban_lanes!(subject: :jobs, lanes: %w[blocked queued running])
      prerequisite = Factories.job_record(repository: repo, issue_number: 5, issue_title: "Finish paving", state: "queued", owner_user: user)
      running = Factories.job_record(repository: repo, issue_number: 6, issue_title: "Raise aqueduct", state: "running", owner_user: user)
      JobDependency.create!(job: running, depends_on_job: prerequisite, source: "manual", created_by_user: user)

      get "/api/v1/app/dashboard", params: { subject: "job", view: "kanban" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(lane_item_ids(body, "running")).to include(running.id)
      expect(lane_item_ids(body, "blocked")).not_to include(running.id)
    end

    it "keeps queued jobs in the queued Kanban lane when the latest workflow snapshot is stale" do
      user.update_dashboard_kanban_lanes!(subject: :jobs, lanes: %w[blocked queued running])
      queued = Factories.job_record(repository: repo, issue_number: 7, issue_title: "Catalog marble", state: "queued", owner_user: user)
      Workflow.create!(job: queued, trigger_kind: "initial", state: "running")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "kanban" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(lane_item_ids(body, "queued")).to include(queued.id)
      expect(lane_item_ids(body, "running")).not_to include(queued.id)
    end

    it "still surfaces non-running jobs with unsatisfied dependencies in the blocked Kanban lane" do
      user.update_dashboard_kanban_lanes!(subject: :jobs, lanes: %w[blocked queued running])
      prerequisite = Factories.job_record(repository: repo, issue_number: 8, issue_title: "Approve quarry", state: "queued", owner_user: user)
      blocked = Factories.job_record(repository: repo, issue_number: 9, issue_title: "Lay road", state: "queued", owner_user: user)
      JobDependency.create!(job: blocked, depends_on_job: prerequisite, source: "manual", created_by_user: user)

      get "/api/v1/app/dashboard", params: { subject: "job", view: "kanban" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(lane_item_ids(body, "blocked")).to include(blocked.id)
      expect(lane_item_ids(body, "queued")).not_to include(blocked.id)
    end

    it "marks the landing queue pause control visible when the landing smart folder is active" do
      user.update!(landing_paused: true)
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Landing queue",
        kind: "user_defined",
        filter: SmartFolder.attention_preset_filter("landing_queue")
      )

      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["landing_queue"]).to eq(
        "visible" => true,
        "paused" => true,
        "toggle_path" => "/api/v1/app/dashboard/landing_pause"
      )
    end

    it "filters dashboard records by ownership scope and persists the preference" do
      teammate = Factories.user(email_address: "teammate@example.com")
      mine = Factories.job_record(repository: repo, issue_number: 11, issue_title: "My aqueduct", owner_user: user)
      teammate_job = Factories.job_record(repository: repo, issue_number: 12, issue_title: "Their forum", owner_user: teammate)
      claimable = Factories.job_record(repository: repo, issue_number: 13, issue_title: "Loose road", owner_user: nil)
      owned_epic = Factories.epic(user: user, repository: repo, title: "Owned epic", owner_user: user)
      unowned_epic = Factories.epic(user: user, repository: repo, title: "Unowned epic", owner_user: nil)
      mine_workflow = Workflow.create!(job: mine, trigger_kind: "initial", state: "queued")
      unowned_workflow = Workflow.create!(job: claimable, trigger_kind: "initial", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job", scope: "mine" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership_scope", "scope")).to eq("mine")
      expect(body.dig("ownership_scope", "owner_user_id")).to eq(user.id)
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ mine.id ])
      expect(body.dig("counts", "jobs")).to eq(1)
      expect(body.dig("preferences", "ownership_scope")).to eq("mine")
      expect(user.reload.dashboard_preferences).to include("last_ownership_scope" => "mine")

      get "/api/v1/app/dashboard", params: { subject: "job", scope: "claimable" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to eq([ claimable.id ])

      get "/api/v1/app/dashboard", params: { subject: "job", scope: "user", owner_user_id: teammate.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership_scope", "owner_user")).to include(
        "id" => teammate.id,
        "email_address" => "teammate@example.com"
      )
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ teammate_job.id ])
      expect(user.reload.dashboard_preferences).to include(
        "last_ownership_scope" => "user",
        "last_owner_user_id" => teammate.id.to_s
      )

      get "/api/v1/app/dashboard", params: { subject: "epic", scope: "mine" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to eq([ owned_epic.id ])

      get "/api/v1/app/dashboard", params: { subject: "epic", scope: "claimable" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to eq([ unowned_epic.id ])

      get "/api/v1/app/dashboard", params: { subject: "workflow", scope: "mine" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to eq([ mine_workflow.id ])

      get "/api/v1/app/dashboard", params: { subject: "workflow", scope: "claimable" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to eq([ unowned_workflow.id ])
    end

    it "defaults job and workflow dashboards to the current user's owned work" do
      user.update_dashboard_preferences!(subject: "job", ownership_scope: "team")
      user.update_dashboard_preferences!(subject: "workflow", ownership_scope: "team")
      mine = Factories.job_record(repository: repo, issue_number: 21, issue_title: "My road", owner_user: user)
      claimable = Factories.job_record(repository: repo, issue_number: 22, issue_title: "Unclaimed road", owner_user: nil)
      mine_workflow = Workflow.create!(job: mine, trigger_kind: "initial", state: "queued")
      Workflow.create!(job: claimable, trigger_kind: "initial", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership_scope", "scope")).to eq("mine")
      expect(body.dig("ownership_scope", "owner_user_id")).to eq(user.id)
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ mine.id ])
      expect(body["items"].map { |item| item.fetch("id") }).not_to include(claimable.id)
      expect(user.reload.dashboard_preferences).to include("last_ownership_scope" => "team")

      get "/api/v1/app/dashboard", params: { subject: "workflow" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership_scope", "scope")).to eq("mine")
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ mine_workflow.id ])
    end

    it "keeps explicit team and user scopes available for dashboard coordination" do
      teammate = Factories.user(email_address: "teammate@example.com")
      mine = Factories.job_record(repository: repo, issue_number: 31, issue_title: "My basilica", owner_user: user)
      teammate_job = Factories.job_record(repository: repo, issue_number: 32, issue_title: "Their basilica", owner_user: teammate)
      claimable = Factories.job_record(repository: repo, issue_number: 33, issue_title: "Loose basilica", owner_user: nil)

      get "/api/v1/app/dashboard", params: { subject: "job", scope: "team" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to contain_exactly(mine.id, teammate_job.id, claimable.id)

      get "/api/v1/app/dashboard", params: { subject: "job", scope: "user", owner_user_id: teammate.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership_scope", "owner_user")).to include(
        "id" => teammate.id,
        "email_address" => "teammate@example.com"
      )
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ teammate_job.id ])
    end

    it "returns validation errors for invalid dashboard ownership params" do
      get "/api/v1/app/dashboard", params: { subject: "job", scope: "somebody_else" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body).to eq(
        "error" => {
          "code" => "validation_failed",
          "message" => "Unknown dashboard scope: somebody_else"
        }
      )

      get "/api/v1/app/dashboard", params: { subject: "job", scope: "user" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to eq("owner_id is required for dashboard scope user")

      get "/api/v1/app/dashboard", params: { subject: "job", scope: "user", owner_id: 99_999_999 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to eq("Unknown dashboard owner user: 99999999")
    end

    it "applies smart folder filters and returns active folder metadata" do
      ready = Factories.epic(user: user, repository: repo, title: "Ready aqueduct", description: "Build a calmer aqueduct.", state: "ready", owner_user: user)
      Factories.epic(user: user, repository: repo, title: "Backlog forum", state: "backlog")
      folder = SmartFolder.create!(
        user: user,
        subject_type: "epic",
        name: "Ready work",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "ready" } ] }
      )

      get "/api/v1/app/dashboard", params: { subject: "epic", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["subject"]).to eq("epic")
      expect(body["total"]).to eq(1)
      expect(body["items"].sole).to include(
        "type" => "epic",
        "id" => ready.id,
        "display_number" => ready.display_number,
        "title" => "Ready aqueduct",
        "description" => "Build a calmer aqueduct.",
        "owner" => nil,
        "owned_by_current_user" => true,
        "claimable" => true,
        "owner_user_id" => user.id,
        "owner_status" => "mine",
        "owner_user" => include("id" => user.id, "email_address" => user.email_address),
        "jobs_count" => 0,
        "paths" => include(
          "epic_path" => epic_path(ready),
          "app_state_path" => "/api/v1/app/epics/#{ready.id}/state",
          "app_claim_path" => "/api/v1/app/epics/#{ready.id}/claim",
          "app_unclaim_path" => "/api/v1/app/epics/#{ready.id}/unclaim"
        )
      )
      expect(body.dig("controls", "columns", "required")).to eq([{ "key" => "epic", "title" => "Epic" }])
      expect(body["active_smart_folder_id"]).to eq(folder.id)
      expect(body["filter"]).to eq(
        "and" => [
          { "field" => "state", "op" => "is", "value" => "ready" }
        ]
      )
      expect(body["smart_folders"]).to include(include(
        "id" => folder.id,
        "name" => "Ready work",
        "visibility" => "user_defined",
        "count" => 1,
        "active" => true
      ))
    end

    it "returns smart folder counts and hides empty when-present built-ins" do
      pinned = Factories.job_record(repository: repo, issue_number: 1, issue_title: "Pinned aqueduct", state: "queued", owner_user: user)
      Factories.job_pin(user: user, job: pinned)
      SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Running jobs",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "running" } ] }
      )

      get "/api/v1/app/dashboard", params: { subject: "job" }

      expect(response).to have_http_status(:ok)
      folders_by_name = parse_body["smart_folders"].index_by { |folder| folder.fetch("name") }
      expect(folders_by_name.fetch("Pinned")).to include(
        "kind" => "builtin",
        "visibility" => "when_present",
        "count" => 1
      )
      expect(folders_by_name).not_to have_key("Landing queue")
      expect(folders_by_name.fetch("Merged this week")).to include(
        "visibility" => "on_demand",
        "count" => 0
      )
      expect(folders_by_name.fetch("Stale")).to include(
        "visibility" => "on_demand",
        "count" => 0
      )
      expect(folders_by_name.fetch("Running jobs")).to include(
        "kind" => "user_defined",
        "visibility" => "user_defined",
        "count" => 0
      )
    end

    it "keeps an active empty when-present smart folder visible" do
      SmartFolder.ensure_builtins!
      folder = SmartFolder.find_by!(user_id: nil, subject_type: "job", name: "Landing queue")

      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["smart_folders"]).to include(include(
        "id" => folder.id,
        "name" => "Landing queue",
        "visibility" => "when_present",
        "count" => 0,
        "active" => true
      ))
    end

    it "returns all workflows for the workflow subject without a hidden recency filter" do
      job = Factories.job_record(repository: repo, issue_number: 10, issue_title: "Old aqueduct", owner_user: user)
      old_workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "succeeded",
        started_at: 30.days.ago,
        finished_at: 29.days.ago
      )

      get "/api/v1/app/dashboard", params: { subject: "workflow", view: "list" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["subject"]).to eq("workflow")
      expect(body["total"]).to eq(1)
      expect(body["items"].sole).to include(
        "type" => "workflow",
        "id" => old_workflow.id,
        "state" => "succeeded",
        "job" => include("title" => "Old aqueduct")
      )
    end

    it "returns workflow dashboard items newest-first by default" do
      newer_job = Factories.job_record(repository: repo, issue_number: 12, issue_title: "Newer aqueduct", owner_user: user)
      older_job = Factories.job_record(repository: repo, issue_number: 11, issue_title: "Older aqueduct", owner_user: user)
      newer_workflow = Workflow.create!(
        job: newer_job,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "succeeded",
        started_at: 10.minutes.ago,
        finished_at: 5.minutes.ago
      )
      older_workflow = Workflow.create!(
        job: older_job,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "succeeded",
        started_at: 1.hour.ago,
        finished_at: 50.minutes.ago
      )

      get "/api/v1/app/dashboard", params: { subject: "workflow", view: "list" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("preferences", "sort")).to include("column" => "started_at", "direction" => "desc")
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ newer_workflow.id, older_workflow.id ])
    end

    it "returns a nullable cost until a job has a billed run" do
      unbilled = Factories.job(repository: repo, issue_number: 1, issue_title: "Wait in queue", owner_user: user)
      billed = Factories.job(repository: repo, issue_number: 2, issue_title: "Spend carefully", owner_user: user)
      billed.initial_run.update!(cost_usd: 0.12)

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list" }

      body = parse_body
      expect(body["items"].find { |item| item.fetch("id") == unbilled.id }.fetch("total_cost_usd")).to be_nil
      expect(body["items"].find { |item| item.fetch("id") == billed.id }.fetch("total_cost_usd")).to eq(0.12)
    end

    it "defaults jobs and workflows to the current executor" do
      mine = Factories.job_record(user: user, repository: repo, issue_number: 20, issue_title: "My aqueduct", owner_user: user)
      my_workflow = Workflow.create!(job: mine, trigger_kind: "initial", state: "queued")
      teammate = Factories.user(email_address: "teammate@example.com")
      teammate_repo = Factories.repository(user: teammate, owner: "acme", name: "api")
      theirs = Factories.job_record(user: teammate, repository: teammate_repo, issue_number: 21, issue_title: "Their forum", owner_user: teammate)
      Workflow.create!(job: theirs, trigger_kind: "initial", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership", "scope")).to eq("mine")
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ mine.id ])
      expect(body.dig("items", 0, "owner_badge")).to be_nil
      expect(body.dig("controls", "ownership_scopes")).to include(
        { "value" => "mine", "label" => "Mine" },
        { "value" => "team", "label" => "Team" },
        { "value" => "user", "label" => "User" }
      )

      get "/api/v1/app/dashboard", params: { subject: "workflow" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to eq([ my_workflow.id ])
    end

    it "defaults epics to mine plus claimable backlog and ready epics" do
      teammate = Factories.user(email_address: "teammate@example.com")
      teammate_repo = Factories.repository(user: teammate, owner: "globex", name: "api")
      mine = Factories.epic(user: teammate, repository: teammate_repo, owner_user: user, state: "in_progress", title: "My claimed epic")
      claimable = Factories.epic(user: teammate, repository: teammate_repo, state: "ready", title: "Claimable epic")
      hidden_claimed = Factories.epic(user: teammate, repository: teammate_repo, owner_user: teammate, state: "ready", title: "Teammate epic")
      hidden_done = Factories.epic(user: teammate, repository: teammate_repo, state: "done", title: "Unclaimed done")

      get "/api/v1/app/dashboard", params: { subject: "epic" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["items"].map { |item| item.fetch("id") }).to contain_exactly(mine.id, claimable.id)
      expect(body["items"].map { |item| item.fetch("id") }).not_to include(hidden_claimed.id, hidden_done.id)
      expect(body["items"].find { |item| item.fetch("id") == mine.id }.fetch("owner_badge")).to be_nil
      expect(body["items"].find { |item| item.fetch("id") == claimable.id }.fetch("owner_badge")).to eq(
        "label" => "Claimable",
        "kind" => "claimable"
      )
    end

    it "supports team and per-user ownership scopes with useful badges" do
      teammate = Factories.user(email_address: "teammate@example.com", first_name: "Team", last_name: "Mate")
      teammate_repo = Factories.repository(user: teammate, owner: "globex", name: "api")
      mine = Factories.job_record(user: user, repository: repo, issue_number: 30, issue_title: "Mine", owner_user: user)
      theirs = Factories.job_record(user: teammate, repository: teammate_repo, issue_number: 31, issue_title: "Theirs", owner_user: teammate)

      get "/api/v1/app/dashboard", params: { subject: "job", ownership_scope: "team" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership", "scope")).to eq("team")
      expect(body["items"].map { |item| item.fetch("id") }).to contain_exactly(mine.id, theirs.id)
      expect(body["items"].find { |item| item.fetch("id") == mine.id }.fetch("owner_badge")).to be_nil
      expect(body["items"].find { |item| item.fetch("id") == theirs.id }.fetch("owner_badge")).to eq(
        "label" => "Team Mate",
        "kind" => "other_user"
      )

      get "/api/v1/app/dashboard", params: { subject: "job", ownership_scope: "user", owner_id: teammate.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership", "scope")).to eq("user")
      expect(body.dig("ownership", "owner_id")).to eq(teammate.id)
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ theirs.id ])
      expect(user.reload.dashboard_preferences.dig("jobs", "ownership_scope")).to eq("user")
      expect(user.dashboard_preferences.dig("jobs", "owner_id")).to eq(teammate.id.to_s)
    end

    it "suppresses ownership badges for single-user dashboards" do
      Factories.epic(user: user, repository: repo, state: "ready", title: "Solo claimable")

      get "/api/v1/app/dashboard", params: { subject: "epic" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership", "team_user_count")).to eq(1)
      expect(body.dig("ownership", "badges_visible")).to eq(false)
      expect(body.dig("items", 0, "owner_badge")).to be_nil
    end
  end

  describe "PATCH /api/v1/app/dashboard/preferences" do
    it "updates dashboard sort, visible columns, and Kanban lanes" do
      patch "/api/v1/app/dashboard/preferences",
            params: {
              subject: "jobs",
              sort_column: "started_at",
              sort_direction: "asc",
              visible_columns: %w[state repository],
              kanban_lanes: %w[queued running]
            },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["message"]).to eq("Dashboard preferences updated.")
      preferences = user.reload.dashboard_preferences.fetch("jobs")
      expect(preferences).to include(
        "sort_column" => "started_at",
        "sort_direction" => "asc",
        "visible_columns" => %w[title state repository],
        "kanban_lanes" => %w[queued running]
      )
    end

    it "returns structured validation errors" do
      patch "/api/v1/app/dashboard/preferences",
            params: { subject: "jobs", sort_column: "vapor", sort_direction: "asc" },
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body).to eq(
        "error" => {
          "code" => "validation_failed",
          "message" => "Unknown dashboard sort column: vapor"
        }
      )
    end
  end

  describe "POST /api/v1/app/dashboard/landing_pause" do
    it "pauses landing" do
      expect {
        post "/api/v1/app/dashboard/landing_pause", as: :json
      }.not_to have_enqueued_job(LandingQueueProcessorJob)

      expect(response).to have_http_status(:ok)
      expect(user.reload.landing_paused).to eq(true)
      expect(parse_body).to include("message" => "Landing paused.", "landing_paused" => true)
    end

    it "resumes landing and kicks the processor" do
      user.update!(landing_paused: true)

      expect {
        post "/api/v1/app/dashboard/landing_pause", as: :json
      }.to have_enqueued_job(LandingQueueProcessorJob)

      expect(response).to have_http_status(:ok)
      expect(user.reload.landing_paused).to eq(false)
      expect(parse_body).to include("message" => "Landing resumed.", "landing_paused" => false)
    end
  end

  describe "POST /api/v1/app/dashboard/jobs/bulk" do
    it "requires selected jobs" do
      post "/api/v1/app/dashboard/jobs/bulk", params: { bulk_action: "close" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to eq("Select at least one job.")
    end

    it "retries eligible jobs" do
      first = Factories.job(repository: repo, issue_number: 1, agent_provider: "claude")
      second = Factories.job(repository: repo, issue_number: 2, agent_provider: "codex")
      finish_initial_work(first, provider: "claude")
      finish_initial_work(second, provider: "codex")

      expect(AppEvents).to receive(:broadcast).with(
        user: user,
        type: "updated",
        resource: "job",
        id: nil,
        changed: [ "bulk" ],
        payload: { "action" => "retry", "affected_job_ids" => contain_exactly(first.id, second.id) }
      )

      expect {
        post "/api/v1/app/dashboard/jobs/bulk",
             params: { job_ids: [ first.id, second.id ], bulk_action: "retry" },
             as: :json
      }.to change { Workflow.where(trigger_kind: "retry").count }.by(2)

      expect(response).to have_http_status(:ok)
      expect(parse_body["message"]).to eq("Retry enqueued for 2 jobs.")
      expect(parse_body["affected_job_ids"]).to contain_exactly(first.id, second.id)
    end

    it "closes selected open jobs without mutating another user's job" do
      mine = Factories.job(repository: repo, issue_number: 1)
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
      theirs = Factories.job(repository: other_repo, issue_number: 2)
      allow(AppEvents).to receive(:broadcast)

      post "/api/v1/app/dashboard/jobs/bulk",
           params: { job_ids: [ mine.id, theirs.id ], bulk_action: "close" },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(mine.reload).to be_closed
      expect(theirs.reload).to be_open
      expect(parse_body["affected_job_ids"]).to eq([ mine.id ])
    end

    it "approves selected implemented jobs and reports auto-merge skips" do
      repo.update!(auto_merge_enabled: true)
      disabled_repo = Factories.repository(user: user, owner: "acme", name: "lib", auto_merge_enabled: false)
      enabled = Factories.job(repository: repo, issue_number: 10)
      disabled = Factories.job(repository: disabled_repo, issue_number: 11)
      enabled.update!(state: "implemented")
      disabled.update!(state: "implemented")
      allow(AppEvents).to receive(:broadcast)

      post "/api/v1/app/dashboard/jobs/bulk",
           params: { job_ids: [ enabled.id, disabled.id ], bulk_action: "approve" },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(enabled.reload).to be_approved
      expect(disabled.reload).to be_implemented
      expect(parse_body["message"]).to include("Approved 1 job in batch")
      expect(parse_body["message"]).to include("Skipped 1 job whose repository has auto-merge disabled (acme/lib)")
      expect(parse_body["skipped_job_ids"]).to eq([ disabled.id ])
      expect(parse_body["batch_id"]).to be_present
    end

    it "returns review payloads for selected implemented jobs" do
      first = Factories.job(repository: repo, issue_number: 1, issue_title: "Review the aqueduct")
      second = Factories.job(repository: repo, issue_number: 2, issue_title: "Review the forum")
      first.update!(state: "implemented")
      second.update!(state: "implemented")
      first.initial_run.update!(agent_diff: "diff --git a/a.txt b/a.txt\n+first")
      second.initial_run.update!(agent_diff: "diff --git a/b.txt b/b.txt\n+second")

      post "/api/v1/app/dashboard/jobs/bulk",
           params: { job_ids: [ first.id, second.id ], bulk_action: "review_approve" },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["review_jobs"].map { |job| job["id"] }).to contain_exactly(first.id, second.id)
      expect(parse_body["review_jobs"].map { |job| job["diff"] }.join("\n")).to include("+first", "+second")
    end

    it "commits reviewed approvals and skips rejected choices" do
      approved = Factories.job(repository: repo, issue_number: 1)
      skipped = Factories.job(repository: repo, issue_number: 2)
      approved.update!(state: "implemented")
      skipped.update!(state: "implemented")
      allow(AppEvents).to receive(:broadcast)

      post "/api/v1/app/dashboard/jobs/bulk",
           params: {
             job_ids: [ approved.id, skipped.id ],
             bulk_action: "commit_review_approval",
             approval_choices: {
               approved.id.to_s => "approve",
               skipped.id.to_s => "skip"
             }
           },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(approved.reload).to be_approved
      expect(skipped.reload).to be_implemented
      expect(parse_body["affected_job_ids"]).to eq([ approved.id ])
    end

    it "applies an existing tag to selected jobs" do
      first = Factories.job(repository: repo, issue_number: 1)
      second = Factories.job(repository: repo, issue_number: 2)
      tag = Factories.tag(user: user, name: "epic:tags", color: "indigo")
      allow(AppEvents).to receive(:broadcast)

      post "/api/v1/app/dashboard/jobs/bulk",
           params: { job_ids: [ first.id, second.id ], bulk_action: "apply_tag", tag_id: tag.id },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(first.reload.tags).to contain_exactly(tag)
      expect(second.reload.tags).to contain_exactly(tag)
      expect(parse_body["message"]).to eq("Applied epic:tags to 2 jobs.")
      expect(parse_body.dig("tag", "name")).to eq("epic:tags")
    end
  end

  describe "POST /api/v1/app/dashboard/epics/bulk" do
    it "requires selected Epics" do
      post "/api/v1/app/dashboard/epics/bulk", params: { bulk_action: "start" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to eq("Select at least one Epic.")
    end

    it "moves selected ready Epics to In Progress and reports skipped Epics" do
      ready = Factories.epic(user: user, repository: repo, title: "Ready aqueduct", state: "ready")
      done = Factories.epic(user: user, repository: repo, title: "Done forum", state: "done")
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
      theirs = Factories.epic(user: other_user, repository: other_repo, title: "Private road", state: "ready")

      allow(AppEvents).to receive(:broadcast)
      expect(AppEvents).to receive(:broadcast).with(
        user: user,
        type: "updated",
        resource: "epic",
        id: nil,
        changed: [ "bulk" ],
        payload: { "action" => "start", "affected_epic_ids" => [ ready.id ] }
      )

      post "/api/v1/app/dashboard/epics/bulk",
           params: { epic_ids: [ ready.id, done.id, theirs.id ], bulk_action: "start" },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(ready.reload).to be_in_progress
      expect(done.reload).to be_done
      expect(theirs.reload).to be_ready
      expect(parse_body).to include(
        "message" => "1 Epic moved to In Progress.",
        "action" => "start",
        "affected_epic_ids" => [ ready.id ],
        "skipped_epic_ids" => [ done.id ]
      )
    end

    it "rejects selections with no ready Epics" do
      done = Factories.epic(user: user, repository: repo, title: "Done forum", state: "done")

      post "/api/v1/app/dashboard/epics/bulk",
           params: { epic_ids: [ done.id ], bulk_action: "start" },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(done.reload).to be_done
      expect(parse_body.dig("error", "message")).to eq("No selected Epics were ready to start.")
    end
  end

  describe "PATCH /api/v1/app/dashboard/epics/:id/auto_approval" do
    it "updates one of the current user's Epics" do
      epic = Factories.epic(user: user, repository: repo, state: "ready", title: "Polish aqueduct")

      patch "/api/v1/app/dashboard/epics/#{epic.id}/auto_approval",
            params: { epic: { auto_approve_mode: "if_graders_pass" } },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(epic.reload.auto_approve_mode).to eq("if_graders_pass")
      expect(parse_body).to include(
        "message" => "Epic auto-approval updated.",
        "epic" => include("id" => epic.id, "auto_approve_mode" => "if_graders_pass")
      )
    end

    it "does not expose another user's Epic" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
      other_epic = Factories.epic(user: other_user, repository: other_repo)

      patch "/api/v1/app/dashboard/epics/#{other_epic.id}/auto_approval",
            params: { epic: { auto_approve_mode: "if_graders_pass" } },
            as: :json

      expect(response).to have_http_status(:not_found)
      expect(other_epic.reload.auto_approve_mode).to eq("never")
    end
  end
end
