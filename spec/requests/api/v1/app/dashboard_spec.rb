require "rails_helper"

RSpec.describe "App API dashboard commands", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  before do
    allow(RepoReconciliationPlan).to receive(:for_epic).and_return(
      RepoReconciliationPlan::Result.new(mode: "none", source: "test", note: nil)
    )
  end

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
      second_workflow = Workflow.create!(job: second, trigger_kind: "rebase", state: "running")
      chat = ChatSession.create!(user: user, repository: repo, title: "Roadmap chat")
      proposal = chat.proposals.create!(
        slug: "build-aqueduct",
        title: "Build aqueduct",
        body: "Bring water across the valley.",
        job: first,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      proposal_message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal proposed." })
      first.update!(claimed_by_user: user, claimed_at: Time.zone.parse("2026-06-03 05:45:00 UTC"))
      first.tags << tag
      archived_repo = Factories.repository(user: user, owner: "acme", name: "archived", archived_at: Time.current)
      archived_job = Factories.job_record(repository: archived_repo, issue_number: 3, issue_title: "Hide archive", state: "queued")
      other_repo = Factories.repository(user: Factories.user, owner: "globex", name: "private")
      other_job = Factories.job_record(repository: other_repo, issue_number: 4, issue_title: "Hide private", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "kanban", scope: "mine" }

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
        "latest_workflow_id" => nil,
        "latest_workflow_trigger_kind" => nil,
        "latest_workflow_state" => "queued",
        "total_cost_usd" => nil,
        "workflows_count" => 0,
        "approved_at" => nil,
        "claimed_at" => "2026-06-03T05:45:00Z",
        "claimed_by_current_user" => true,
        "claimed_by_user" => include("id" => user.id, "profile_path" => "/profiles/#{user.id}"),
        "dependencies_overridden_at" => nil,
        "issue_url" => "https://github.com/acme/widgets/issues/1",
        "pr_url" => "https://github.com/acme/widgets/pull/17",
        "active_workflow_trigger_kind" => nil,
        "repository" => include("slug" => "acme/widgets", "repository_path" => repository_path(repo)),
        "source_chat" => include(
          "chat_id" => chat.id,
          "proposal_id" => proposal.id,
          "message_id" => proposal_message.id,
          "path" => "/chats/#{chat.id}#message-#{proposal_message.id}",
          "label" => "Job proposal in Roadmap chat"
        ),
        "epic" => {
          "id" => epic.id,
          "number" => epic.number,
          "display_number" => epic.slug,
          "path" => epic_path(epic)
        },
        "tags" => [ include("name" => "aqueduct", "color" => "blue") ],
        "paths" => include("job_path" => job_path(first), "source_path" => source_job_path(first))
      )
      expect(body["items"].first["retry_state"]).to include(
        "classification_label" => "Unclassified",
        "state_label" => "No failure"
      )
      expect(body["items"].find { |item| item.fetch("id") == second.id }).to include(
        "active_workflow_trigger_kind" => "rebase",
        "latest_workflow_id" => second_workflow.id,
        "latest_workflow_trigger_kind" => "rebase",
        "latest_workflow_state" => "running"
      )
      expect(body["items"].map { |item| item.fetch("id") }).not_to include(archived_job.id, other_job.id)
      expect(body.dig("preferences", "sort")).to include("column" => "title", "direction" => "asc")
      expect(body["controls"]).to include(
        "views" => %w[list kanban dependencies],
        "sort_columns" => %w[title state repository landing_queue_position created_at started_at priority commits_behind_base],
        "sort_directions" => %w[asc desc],
        "columns" => {
          "required" => [
            { "key" => "checkbox", "title" => "Checkbox" },
            { "key" => "issue", "title" => "Issue" }
          ],
          "optional" => include(
            { "key" => "state", "title" => "State" },
            { "key" => "repository", "title" => "Repository" },
            { "key" => "owner", "title" => "Owner" },
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
    end

    it "can split dashboard chrome from row data" do
      Factories.job_record(repository: repo, issue_number: 1, issue_title: "Build aqueduct", state: "queued", owner_user: user)

      get "/api/v1/app/dashboard", params: { subject: "job", section: "chrome" }

      expect(response).to have_http_status(:ok)
      chrome = parse_body
      expect(chrome).to include(
        "subject" => "job",
        "counts" => include("jobs" => 1),
        "controls" => include("views" => %w[list kanban dependencies]),
        "smart_folders" => be_an(Array)
      )
      expect(chrome).not_to have_key("items")
      expect(chrome).not_to have_key("lanes")
      expect(chrome).not_to have_key("total")

      get "/api/v1/app/dashboard", params: { subject: "job", section: "rows" }

      expect(response).to have_http_status(:ok)
      rows = parse_body
      expect(rows).to include(
        "subject" => "job",
        "total" => 1,
        "items" => contain_exactly(include("title" => "Build aqueduct")),
        "lanes" => []
      )
      expect(rows).not_to have_key("counts")
      expect(rows).not_to have_key("controls")
      expect(rows).not_to have_key("smart_folders")
    end

    it "presents deferred auto-merge workflows as postponed dashboard state" do
      job = Factories.job_record(repository: repo, owner_user: user, issue_number: 30, issue_title: "Land after GitHub settles")
      workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "cancelled")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: "all", scope: "mine" }

      expect(response).to have_http_status(:ok)
      job_item = parse_body.fetch("items").find { |item| item.fetch("id") == job.id }
      expect(job_item).to include(
        "latest_workflow_id" => workflow.id,
        "latest_workflow_trigger_kind" => "auto_merge",
        "latest_workflow_state" => "postponed"
      )

      get "/api/v1/app/dashboard", params: { subject: "workflow", view: "list", scope: "mine" }

      expect(response).to have_http_status(:ok)
      workflow_item = parse_body.fetch("items").find { |item| item.fetch("id") == workflow.id }
      expect(workflow_item).to include(
        "trigger_kind" => "auto_merge",
        "state" => "postponed"
      )
    end

    it "combines merged-this-week attention with a title contains filter" do
      matching = Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 31,
        issue_title: "Polish CLI checkout",
        state: "closed",
        closure_reason: "pr_merged",
        finished_at: 1.day.ago
      )
      Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 32,
        issue_title: "Polish dashboard",
        state: "closed",
        closure_reason: "pr_merged",
        finished_at: 1.day.ago
      )
      Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 33,
        issue_title: "Old CLI cleanup",
        state: "closed",
        closure_reason: "pr_merged",
        finished_at: 8.days.ago
      )
      tree = {
        "and" => [
          { "field" => "attention", "op" => "is", "value" => "merged_this_week" },
          { "field" => "title", "op" => "contains", "value" => "cli" }
        ]
      }

      get "/api/v1/app/dashboard",
          params: { subject: "job", view: "list", scope: "team", q: Filters::QueryParam.encode(tree) }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("items").map { |item| item.fetch("id") }).to eq([ matching.id ])
    end

    it "does not persist dashboard navigation during a read" do
      original_preferences = user.dashboard_preferences

      get "/api/v1/app/dashboard", params: { subject: "workflow", view: "kanban", scope: "team" }

      expect(response).to have_http_status(:ok)
      expect(parse_body).to include("subject" => "workflow", "view" => "kanban")
      expect(user.reload.dashboard_preferences).to eq(original_preferences)
    end

    it "returns ranked suggestions from recorded filter usage" do
      state_tree = {
        "and" => [
          { "field" => "state", "op" => "is", "value" => "running" }
        ]
      }
      repository_tree = {
        "and" => [
          { "field" => "repository_id", "op" => "is", "value" => repo.id.to_s }
        ]
      }

      2.times do
        Filters::Suggestions.record!(user: user, surface: "dashboard", subject: "job", tree: state_tree)
      end
      Filters::Suggestions.record!(user: user, surface: "dashboard", subject: "job", tree: repository_tree)

      get "/api/v1/app/dashboard", params: { subject: "job" }

      expect(response).to have_http_status(:ok)
      suggestions = parse_body.dig("controls", "filter_suggestions")
      expect(suggestions.map { |suggestion| suggestion.fetch("label") }).to eq([
        "State is Running",
        "Repository is acme/widgets"
      ])
      expect(suggestions.first).to include(
        "filter" => { "field" => "state", "op" => "is", "value" => "running" },
        "use_count" => 2
      )

      get "/api/v1/app/dashboard", params: { subject: "job", q: Filters::QueryParam.encode(state_tree) }

      expect(response).to have_http_status(:ok)
      active_suggestions = parse_body.dig("controls", "filter_suggestions")
      expect(active_suggestions.map { |suggestion| suggestion.fetch("label") }).not_to include("State is Running")
      expect(active_suggestions.map { |suggestion| suggestion.fetch("label") }).to include("Repository is acme/widgets")
    end

    it "does not record filter usage while rendering the dashboard" do
      tree = {
        "and" => [
          { "field" => "state", "op" => "is", "value" => "running" }
        ]
      }
      expect(Filters::Suggestions).not_to receive(:record!)

      get "/api/v1/app/dashboard", params: { subject: "job", q: Filters::QueryParam.encode(tree) }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("subject")).to eq("job")
    end

    it "keeps running jobs in the running Kanban lane even when blocked diagnostics are visible" do
      user.update_dashboard_kanban_lanes!(subject: :jobs, lanes: %w[blocked queued running])
      prerequisite = Factories.job_record(repository: repo, owner_user: user, issue_number: 5, issue_title: "Finish paving", state: "queued")
      running = Factories.job_record(repository: repo, owner_user: user, issue_number: 6, issue_title: "Raise aqueduct", state: "running")
      JobDependency.create!(job: running, depends_on_job: prerequisite, source: "manual", created_by_user: user)

      get "/api/v1/app/dashboard", params: { subject: "job", view: "kanban" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(lane_item_ids(body, "running")).to include(running.id)
      expect(lane_item_ids(body, "blocked")).not_to include(running.id)
    end

    it "keeps queued jobs in the queued Kanban lane when the latest workflow snapshot is stale" do
      user.update_dashboard_kanban_lanes!(subject: :jobs, lanes: %w[blocked queued running])
      queued = Factories.job_record(repository: repo, owner_user: user, issue_number: 7, issue_title: "Catalog marble", state: "queued")
      Workflow.create!(job: queued, trigger_kind: "initial", state: "running")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "kanban" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(lane_item_ids(body, "queued")).to include(queued.id)
      expect(lane_item_ids(body, "running")).not_to include(queued.id)
    end

    it "still surfaces non-running jobs with unsatisfied dependencies in the blocked Kanban lane" do
      user.update_dashboard_kanban_lanes!(subject: :jobs, lanes: %w[blocked queued running])
      prerequisite = Factories.job_record(repository: repo, owner_user: user, issue_number: 8, issue_title: "Approve quarry", state: "queued")
      blocked = Factories.job_record(repository: repo, owner_user: user, issue_number: 9, issue_title: "Lay road", state: "queued")
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
        "toggle_path" => "/api/v1/app/dashboard/landing_pause",
        "entries" => []
      )
    end

    it "includes landing_paused in health_blocked_repositories entries" do
      repo.update!(grader_health: "broken", landing_paused: true)
      other = Factories.repository(user: user, owner: "acme", name: "widgets2")
      other.update!(grader_health: "broken", landing_paused: false)

      get "/api/v1/app/dashboard", params: { subject: "job" }

      expect(response).to have_http_status(:ok)
      entries = parse_body["health_blocked_repositories"]
      expect(entries.find { |r| r["id"] == repo.id }).to include(
        "landing_paused" => true,
        "repair_path" => "/api/v1/app/repositories/#{repo.id}/repair_main_branch",
        "main_branch_repair" => include(
          "can_request" => true,
          "can_spawn" => false,
          "blocked_reason" => "waiting_for_health_signals",
          "failed_jobs" => []
        )
      )
      expect(entries.find { |r| r["id"] == other.id }).to include("landing_paused" => false)
    end

    it "adds landing queue positions when the landing smart folder is active" do
      repo.update!(auto_merge_enabled: true)
      first = Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 21,
        issue_title: "First in line",
        state: "approved",
        pr_number: 21,
        approved_at: 2.hours.ago
      )
      second = Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 22,
        issue_title: "Second in line",
        state: "approved",
        pr_number: 22,
        approved_at: 1.hour.ago
      )
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Landing queue",
        kind: "user_defined",
        filter: SmartFolder.attention_preset_filter("landing_queue")
      )

      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("controls", "columns", "required")).to include(
        { "key" => "landing_queue_position", "title" => "Queue" }
      )
      expect(body.dig("controls", "sort_columns")).to include("landing_queue_position")
      positions = body.fetch("items").index_by { |item| item.fetch("id") }.transform_values { |item| item.fetch("landing_queue_position") }
      expect(positions).to include(first.id => 1, second.id => 2)
    end

    it "does not assign landing queue positions to blocked jobs" do
      repo.update!(auto_merge_enabled: true)
      blocked = Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 21,
        issue_title: "Missing pull request",
        state: "approved",
        pr_number: nil,
        approved_at: 2.hours.ago
      )
      eligible = Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 22,
        issue_title: "Ready to land",
        state: "approved",
        pr_number: 22,
        approved_at: 1.hour.ago
      )
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Landing queue",
        kind: "user_defined",
        filter: SmartFolder.attention_preset_filter("landing_queue")
      )

      user.update_dashboard_sort!(subject: "job", column: "landing_queue_position", direction: "asc")
      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.fetch("items").map { |item| item.fetch("id") }).to eq([ eligible.id, blocked.id ])
      positions = body.fetch("items").index_by { |item| item.fetch("id") }.transform_values { |item| item.fetch("landing_queue_position") }
      expect(positions).to include(eligible.id => 1, blocked.id => nil)
      blocked_reasons = body.fetch("items").index_by { |item| item.fetch("id") }.transform_values { |item| item.fetch("landing_queue_blocked_reason") }
      expect(blocked_reasons).to include(eligible.id => nil, blocked.id => "missing pull request")
    end

    it "includes landing_queue_blocked_reason in landing queue required columns" do
      repo.update!(auto_merge_enabled: true)
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Landing queue",
        kind: "user_defined",
        filter: SmartFolder.attention_preset_filter("landing_queue")
      )

      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("controls", "columns", "required")).to include(
        { "key" => "landing_queue_blocked_reason", "title" => "Blocked reason" }
      )
    end

    it "includes transitive landing queue blockers and dependency edges by group" do
      repo.update!(auto_merge_enabled: true)
      epic = Factories.epic(user: user, repository: repo, owner_user: user, state: "in_progress", title: "Forum release")
      other_epic = Factories.epic(user: user, repository: repo, owner_user: user, state: "in_progress", title: "Quarry release")
      approved = Factories.job_record(
        repository: repo,
        owner_user: user,
        epic: epic,
        issue_number: 21,
        issue_title: "Land forum paving",
        state: "approved",
        pr_number: 21,
        approved_at: 1.hour.ago
      )
      blocker = Factories.job_record(
        repository: repo,
        owner_user: user,
        epic: other_epic,
        issue_number: 22,
        issue_title: "Ship quarry stones",
        state: "implemented",
        pr_number: 22
      )
      root_blocker = Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 23,
        issue_title: "Survey road",
        state: "queued",
        pr_number: 23
      )
      JobDependency.create!(job: approved, depends_on_job: blocker, source: "manual", created_by_user: user)
      JobDependency.create!(job: blocker, depends_on_job: root_blocker, source: "manual", created_by_user: user)
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Landing queue",
        kind: "user_defined",
        filter: SmartFolder.attention_preset_filter("landing_queue")
      )

      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.fetch("items").find { |item| item.fetch("id") == approved.id }).to include(
        "landing_queue_position" => nil,
        "landing_queue_entry_key" => "epic:#{epic.id}"
      )
      entry = body.fetch("landing_queue").fetch("entries").sole
      expect(entry).to include(
        "key" => "epic:#{epic.id}",
        "position" => 1,
        "job_ids" => [ approved.id ]
      )
      expect(entry.fetch("blocker_jobs")).to contain_exactly(
        include(
          "id" => root_blocker.id,
          "title" => "Survey road",
          "job_path" => "/jobs/#{root_blocker.id}",
          "state" => "queued",
          "pr_number" => 23,
          "pr_path" => "https://github.com/#{repo.slug}/pull/23",
          "epic_id" => nil,
          "epic_title" => nil
        ),
        include(
          "id" => blocker.id,
          "title" => "Ship quarry stones",
          "job_path" => "/jobs/#{blocker.id}",
          "state" => "implemented",
          "pr_number" => 22,
          "pr_path" => "https://github.com/#{repo.slug}/pull/22",
          "epic_id" => other_epic.id,
          "epic_title" => "Quarry release"
        )
      )
      expect(entry.fetch("dependency_edges")).to contain_exactly(
        { "from_job_id" => root_blocker.id, "to_job_id" => blocker.id },
        { "from_job_id" => blocker.id, "to_job_id" => approved.id }
      )
    end

    it "includes unapproved Epic sibling blockers without cross-Epic attribution" do
      repo.update!(auto_merge_enabled: true)
      epic = Factories.epic(user: user, repository: repo, owner_user: user, state: "in_progress", title: "Forum release")
      approved = Factories.job_record(
        repository: repo,
        owner_user: user,
        epic: epic,
        issue_number: 21,
        issue_title: "Land forum paving",
        state: "approved",
        pr_number: 21,
        approved_at: 1.hour.ago
      )
      sibling = Factories.job_record(
        repository: repo,
        owner_user: user,
        epic: epic,
        issue_number: 22,
        issue_title: "Finish forum benches",
        state: "implemented",
        pr_number: 22
      )
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Landing queue",
        kind: "user_defined",
        filter: SmartFolder.attention_preset_filter("landing_queue")
      )

      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      entry = parse_body.fetch("landing_queue").fetch("entries").sole
      expect(entry).to include(
        "key" => "epic:#{epic.id}",
        "position" => 1,
        "job_ids" => [ approved.id ]
      )
      expect(entry.fetch("blocker_jobs")).to contain_exactly(
        include(
          "id" => sibling.id,
          "title" => "Finish forum benches",
          "job_path" => "/jobs/#{sibling.id}",
          "state" => "implemented",
          "pr_number" => 22,
          "pr_path" => "https://github.com/#{repo.slug}/pull/22"
        )
      )
      expect(entry.fetch("blocker_jobs").sole).not_to include("epic_id", "epic_title")
    end

    it "groups Epic jobs together when assigning landing queue positions" do
      repo.update!(auto_merge_enabled: true)
      epic = Factories.epic(user: user, repository: repo, owner_user: user, state: "in_progress")
      epic_child = Factories.job_record(
        repository: repo,
        owner_user: user,
        epic: epic,
        issue_number: 21,
        issue_title: "Epic child",
        state: "approved",
        pr_number: 21,
        approved_at: 3.hours.ago
      )
      loose = Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 22,
        issue_title: "Loose job",
        state: "approved",
        pr_number: 22,
        approved_at: 2.hours.ago
      )
      epic_parent = Factories.job_record(
        repository: repo,
        owner_user: user,
        epic: epic,
        issue_number: 23,
        issue_title: "Epic parent",
        state: "approved",
        pr_number: 23,
        approved_at: 1.hour.ago
      )
      epic_child.update!(parent_job: epic_parent)
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Landing queue",
        kind: "user_defined",
        filter: SmartFolder.attention_preset_filter("landing_queue")
      )

      user.update_dashboard_sort!(subject: "job", column: "landing_queue_position", direction: "asc")
      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.fetch("items").map { |item| item.fetch("id") }).to eq([ epic_parent.id, loose.id, epic_child.id ])
      positions = body.fetch("items").index_by { |item| item.fetch("id") }.transform_values { |item| item.fetch("landing_queue_position") }
      expect(positions).to include(epic_parent.id => 1, loose.id => 2, epic_child.id => nil)
    end

    it "sorts by landing queue position when the landing smart folder is active" do
      repo.update!(auto_merge_enabled: true)
      first = Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 21,
        issue_title: "First in line",
        state: "approved",
        pr_number: 21,
        approved_at: 2.hours.ago
      )
      second = Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 22,
        issue_title: "Second in line",
        state: "approved",
        pr_number: 22,
        approved_at: 1.hour.ago
      )
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Landing queue",
        kind: "user_defined",
        filter: SmartFolder.attention_preset_filter("landing_queue")
      )

      user.update_dashboard_sort!(subject: "job", column: "landing_queue_position", direction: "asc")
      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("items").map { |item| item.fetch("id") }).to eq([ first.id, second.id ])

      user.update_dashboard_sort!(subject: "job", column: "landing_queue_position", direction: "desc")
      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("items").map { |item| item.fetch("id") }).to eq([ second.id, first.id ])
    end

    it "filters dashboard records by ownership scope" do
      teammate = Factories.user(email_address: "teammate@example.com")
      owned_epic = Factories.epic(user: user, repository: repo, title: "Owned epic", owner_user: user)
      unowned_epic = Factories.epic(user: user, repository: repo, title: "Unowned epic", owner_user: nil)
      unowned_done_epic = Factories.epic(user: user, repository: repo, title: "Unowned done epic", owner_user: nil, state: "done")
      mine = Factories.job_record(repository: repo, issue_number: 11, issue_title: "My aqueduct", owner_user: user)
      teammate_job = Factories.job_record(repository: repo, issue_number: 12, issue_title: "Their forum", owner_user: teammate)
      # Epicless jobs are never claimable (they own to their creator at
      # creation). A claimable job is an unowned Epic child — claimed by
      # claiming its Epic.
      claimable = Factories.job_record(repository: repo, issue_number: 13, issue_title: "Loose road", owner_user: nil, epic: unowned_epic)
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

      get "/api/v1/app/dashboard", params: { subject: "epic", scope: "mine" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to contain_exactly(owned_epic.id, unowned_epic.id)

      get "/api/v1/app/dashboard", params: { subject: "epic", scope: "claimable" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to eq([ unowned_epic.id ])
      expect(parse_body["items"].map { |item| item.fetch("id") }).not_to include(unowned_done_epic.id)

      get "/api/v1/app/dashboard", params: { subject: "workflow", scope: "mine" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to eq([ mine_workflow.id ])

      get "/api/v1/app/dashboard", params: { subject: "workflow", scope: "claimable" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to eq([ unowned_workflow.id ])
    end

    it "excludes epicless NULL-owner jobs from the claimable pool (legacy data)" do
      # A pre-backfill epicless job can still have a NULL owner. It must not
      # appear as claimable — epicless jobs belong to their creator.
      legacy = Factories.job_record(repository: repo, issue_number: 41, issue_title: "Orphan road", owner_user: user)
      legacy.update_column(:owner_user_id, nil)

      get "/api/v1/app/dashboard", params: { subject: "job", scope: "claimable" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).not_to include(legacy.id)
    end

    it "defaults job and workflow dashboards to team work" do
      user.update_dashboard_preferences!(subject: "job", ownership_scope: "team")
      user.update_dashboard_preferences!(subject: "workflow", ownership_scope: "team")
      mine = Factories.job_record(repository: repo, issue_number: 21, issue_title: "My road", owner_user: user)
      claimable = Factories.job_record(repository: repo, issue_number: 22, issue_title: "Unclaimed road", owner_user: nil)
      mine_workflow = Workflow.create!(job: mine, trigger_kind: "initial", state: "queued")
      claimable_workflow = Workflow.create!(job: claimable, trigger_kind: "initial", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership_scope", "scope")).to eq("team")
      expect(body.dig("ownership_scope", "owner_user_id")).to be_nil
      expect(body["items"].map { |item| item.fetch("id") }).to contain_exactly(mine.id, claimable.id)

      get "/api/v1/app/dashboard", params: { subject: "workflow" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership_scope", "scope")).to eq("team")
      expect(body["items"].map { |item| item.fetch("id") }).to contain_exactly(mine_workflow.id, claimable_workflow.id)
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
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "ready" } ] },
        position: 2
      )

      get "/api/v1/app/dashboard", params: { subject: "epic", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["subject"]).to eq("epic")
      expect(body["total"]).to eq(1)
      expect(body["items"].sole).to include(
        "type" => "epic",
        "id" => ready.id,
        "display_number" => ready.slug,
        "title" => "Ready aqueduct",
        "description" => "Build a calmer aqueduct.",
        "owner" => nil,
        "owned_by_current_user" => true,
        "claimable" => true,
        "owner_user_id" => user.id,
        "owner_status" => "mine",
        "owner_user" => include("id" => user.id, "email_address" => user.email_address),
        "stuck" => false,
        "all_jobs_closed" => false,
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
        "position" => folder.position,
        "visibility" => "user_defined",
        "count" => 1,
        "active" => true,
        "filter" => {
          "and" => [
            { "field" => "state", "op" => "is", "value" => "ready" }
          ]
        }
      ))
    end

    it "returns landed child job progress for Epics" do
      epic = Factories.epic(user: user, repository: repo, title: "Repair roads", state: "in_progress")
      Factories.job_record(repository: repo, epic: epic, issue_number: 31, issue_title: "Merge paving", state: "closed", closure_reason: "pr_merged")
      Factories.job_record(repository: repo, epic: epic, issue_number: 32, issue_title: "External bridge", state: "closed", closure_reason: "external_pr_merged")
      Factories.job_record(repository: repo, epic: epic, issue_number: 33, issue_title: "Cancelled canal", state: "closed", closure_reason: "cancelled")
      Factories.job_record(repository: repo, epic: epic, issue_number: 34, issue_title: "Open gate", state: "implemented")

      get "/api/v1/app/dashboard", params: { subject: "epic", view: "kanban" }

      expect(response).to have_http_status(:ok)
      item = parse_body.fetch("lanes").flat_map { |lane| lane.fetch("items") }.find { |row| row.fetch("id") == epic.id }
      expect(item).to include(
        "jobs_count" => 4,
        "landed_jobs_count" => 2,
        "all_jobs_closed" => false,
        "job_state_counts" => { "closed" => 2, "preempted" => 1, "implemented" => 1 }
      )
    end

    it "returns smart folder counts and hides empty when-present built-ins" do
      pinned = Factories.job_record(repository: repo, issue_number: 1, issue_title: "Pinned aqueduct", state: "queued", owner_user: user)
      Factories.job_pin(user: user, job: pinned)
      Factories.job_record(
        repository: repo,
        owner_user: user,
        issue_number: 2,
        issue_title: "Failed landing",
        state: "implemented",
        landing_failure_reason: "auto_merge: required grader failed"
      )
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
        "count" => 1,
        "attention_preset" => "pinned"
      )
      expect(folders_by_name.fetch("Queued")).to include(
        "kind" => "builtin",
        "visibility" => "when_present",
        "count" => 1
      )
      expect(folders_by_name.fetch("Inbox")).to include("count" => 1, "attention_preset" => "inbox")
      expect(folders_by_name.fetch("Just failed")).to include(
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
        "count" => 0,
        "attention_preset" => nil
      )
    end

    it "includes attention_preset on smart folders for the landing queue sort race fix" do
      SmartFolder.ensure_builtins!
      lq_folder = SmartFolder.find_builtin_by_attention("landing_queue")
      Factories.job_record(repository: repo, owner_user: user, issue_number: 10, issue_title: "Land me", state: "approved")

      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: lq_folder.id }

      expect(response).to have_http_status(:ok)
      folders_by_name = parse_body["smart_folders"].index_by { |f| f.fetch("name") }
      expect(folders_by_name.fetch("Landing queue")).to include("attention_preset" => "landing_queue")
      expect(folders_by_name.fetch("Inbox")).to include("attention_preset" => "inbox")
    end

    it "defaults the plain jobs list dashboard to Inbox and keeps All jobs addressable" do
      teammate = Factories.user(email_address: "teammate@example.com")
      teammate_repo = Factories.repository(user: teammate, owner: "acme", name: "teammate-widgets")
      inbox_job = Factories.job_record(repository: repo, owner_user: user, issue_number: 41, issue_title: "Ready for review", state: "implemented")
      other_inbox_job = Factories.job_record(user: teammate, repository: teammate_repo, owner_user: teammate, issue_number: 43, issue_title: "Someone else's review", state: "implemented")
      closed_job = Factories.job_record(repository: repo, owner_user: user, issue_number: 42, issue_title: "Already merged", state: "closed", closure_reason: "pr_merged", finished_at: 1.day.ago)

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      inbox_folder = SmartFolder.find_builtin_by_attention("inbox")
      expect(body["active_smart_folder_id"]).to eq(inbox_folder.id)
      expect(body["filter"]).to eq(
        "and" => [
          { "field" => "attention", "op" => "is", "value" => "inbox" },
          { "field" => "job_type", "op" => "is", "value" => "user" },
          { "field" => "owner_user_id", "op" => "is", "value" => "me" }
        ]
      )
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ inbox_job.id ])
      expect(body["items"].map { |item| item.fetch("id") }).not_to include(other_inbox_job.id)

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: "all" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["active_smart_folder_id"]).to be_nil
      expect(body["filter"]).to eq("and" => [])
      expect(body["items"].map { |item| item.fetch("id") }).to include(inbox_job.id, closed_job.id)
    end

    it "uses a saved jobs smart folder before the Inbox default" do
      SmartFolder.ensure_builtins!
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "My work",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "running" } ] }
      )
      user.update_dashboard_smart_folder!(subject: "job", smart_folder_id: folder.id)

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["active_smart_folder_id"]).to eq(folder.id)
      expect(body["filter"]).to eq(folder.filter)
    end

    it "returns only URL filters in the editable filter payload while querying with an active smart folder" do
      folder_tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "open" } ] }
      q_tree = { "and" => [ { "field" => "kind", "op" => "is", "value" => "direct" } ] }
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Open work",
        kind: "user_defined",
        filter: folder_tree
      )
      direct_open = Factories.job_record(repository: repo, owner_user: user, issue_number: nil, issue_title: "Direct open", kind: "direct", state: "queued")
      Factories.job_record(repository: repo, owner_user: user, issue_number: 43, issue_title: "Issue open", kind: "issue", state: "queued")
      direct_closed = Factories.job_record(repository: repo, owner_user: user, issue_number: nil, issue_title: "Direct closed", kind: "direct", state: "closed")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: folder.id, q: Filters::QueryParam.encode(q_tree) }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["filter"]).to eq(q_tree)
      expect(body["items"].map { |item| item.fetch("id") }).to contain_exactly(direct_open.id, direct_closed.id)
      expect(body["smart_folders"].find { |row| row.fetch("id") == folder.id }).to include(
        "filter" => folder_tree,
        "active" => true
      )
    end

    it "treats a URL chip edit as a replacement instead of ANDing with the active smart folder" do
      folder_tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "open" } ] }
      q_tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "closed" } ] }
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Open work",
        kind: "user_defined",
        filter: folder_tree
      )
      Factories.job_record(repository: repo, owner_user: user, issue_number: 43, issue_title: "Open issue", kind: "issue", state: "queued")
      closed = Factories.job_record(repository: repo, owner_user: user, issue_number: 44, issue_title: "Closed issue", kind: "issue", state: "closed")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: folder.id, q: Filters::QueryParam.encode(q_tree) }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["filter"]).to eq(q_tree)
      expect(body["items"].map { |item| item.fetch("id") }).to eq([ closed.id ])
    end

    it "includes system jobs in the all-jobs view when no smart folder filter is active" do
      user_job = Factories.job_record(repository: repo, owner_user: user, issue_number: 10, issue_title: "Build aqueduct", kind: "issue", state: "queued")
      system_job = Factories.job_record(repository: repo, owner_user: user, issue_number: nil, issue_title: "main_grader:abc123", kind: "main_grader", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: "all" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to contain_exactly(user_job.id, system_job.id)
    end

    it "excludes system jobs from predefined smart folder views via the job_type:user filter" do
      SmartFolder.ensure_builtins!
      queued_folder = SmartFolder.find_by!(user_id: nil, subject_type: "job", name: "Queued")
      user_job = Factories.job_record(repository: repo, owner_user: user, issue_number: 10, state: "queued")
      Factories.job_record(repository: repo, owner_user: user, issue_number: nil, kind: "main_grader", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: queued_folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to contain_exactly(user_job.id)
    end

    it "shows system jobs in the All jobs builtin smart folder" do
      SmartFolder.ensure_builtins!
      all_folder = SmartFolder.find_by!(user_id: nil, subject_type: "job", name: "All jobs")
      user_job = Factories.job_record(repository: repo, owner_user: user, issue_number: 10, state: "queued")
      system_job = Factories.job_record(repository: repo, owner_user: user, issue_number: nil, kind: "main_grader", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: all_folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["items"].map { |item| item.fetch("id") }).to contain_exactly(user_job.id, system_job.id)
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
        created_at: 30.days.ago,
        started_at: 30.days.ago,
        finished_at: 29.days.ago
      )
      10.times do |index|
        Workflow.create!(
          job: job,
          trigger_kind: "retry",
          agent_provider: "claude",
          state: "succeeded",
          created_at: index.days.ago
        )
      end

      get "/api/v1/app/dashboard", params: { subject: "workflow", view: "list" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["subject"]).to eq("workflow")
      expect(body["total"]).to eq(11)
      old_item = body["items"].find { |item| item["id"] == old_workflow.id }
      expect(old_item).to include(
        "type" => "workflow",
        "id" => old_workflow.id,
        "slug" => "WF-#{old_workflow.id}",
        "path" => "/jobs/#{job.id}?tab=workflows&workflows_page=2#workflow-#{old_workflow.id}",
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
      unbilled = Factories.job(repository: repo, owner_user: user, issue_number: 1, issue_title: "Wait in queue")
      billed = Factories.job(repository: repo, owner_user: user, issue_number: 2, issue_title: "Spend carefully")
      billed.initial_run.update!(cost_usd: 0.12)

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: "all" }

      body = parse_body
      expect(body["items"].find { |item| item.fetch("id") == unbilled.id }.fetch("total_cost_usd")).to be_nil
      expect(body["items"].find { |item| item.fetch("id") == billed.id }.fetch("total_cost_usd")).to eq(0.12)
    end

    it "defaults jobs and workflows to team work" do
      mine = Factories.job_record(user: user, repository: repo, owner_user: user, issue_number: 20, issue_title: "My aqueduct")
      my_workflow = Workflow.create!(job: mine, trigger_kind: "initial", state: "queued")
      teammate = Factories.user(email_address: "teammate@example.com")
      teammate_repo = Factories.repository(user: teammate, owner: "acme", name: "api")
      theirs = Factories.job_record(user: teammate, repository: teammate_repo, owner_user: teammate, issue_number: 21, issue_title: "Their forum")
      their_workflow = Workflow.create!(job: theirs, trigger_kind: "initial", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership", "scope")).to eq("team")
      expect(body["items"].map { |item| item.fetch("id") }).to contain_exactly(mine.id, theirs.id)
      expect(body["items"].find { |item| item.fetch("id") == mine.id }.fetch("owner_badge")).to be_nil
      expect(body.dig("controls", "ownership_scopes")).to include(
        { "value" => "mine", "label" => "Mine" },
        { "value" => "team", "label" => "Team" },
        { "value" => "user", "label" => "User" }
      )

      get "/api/v1/app/dashboard", params: { subject: "workflow" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership", "scope")).to eq("team")
      expect(body["items"].map { |item| item.fetch("id") }).to contain_exactly(my_workflow.id, their_workflow.id)
    end

    it "defaults epics to team scope (all active epics)" do
      teammate = Factories.user(email_address: "teammate@example.com")
      teammate_repo = Factories.repository(user: teammate, owner: "globex", name: "api")
      mine = Factories.epic(user: teammate, repository: teammate_repo, owner: user, state: "in_progress", title: "My claimed epic")
      mine_owner_user = Factories.epic(user: teammate, repository: teammate_repo, owner_user: user, state: "ready", title: "My owner-user epic")
      claimable_backlog = Factories.epic(user: teammate, repository: teammate_repo, state: "backlog", title: "Claimable backlog epic")
      claimable = Factories.epic(user: teammate, repository: teammate_repo, state: "ready", title: "Claimable epic")
      teammate_claimed = Factories.epic(user: teammate, repository: teammate_repo, owner: teammate, state: "ready", title: "Teammate epic")
      teammate_owner_user = Factories.epic(user: teammate, repository: teammate_repo, owner_user: teammate, state: "ready", title: "Teammate owner-user epic")
      done_unclaimed = Factories.epic(user: teammate, repository: teammate_repo, state: "done", title: "Unclaimed done")

      get "/api/v1/app/dashboard", params: { subject: "epic" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("ownership", "scope")).to eq("team")
      expect(body["items"].map { |item| item.fetch("id") }).to include(
        mine.id, mine_owner_user.id, claimable_backlog.id, claimable.id,
        teammate_claimed.id, teammate_owner_user.id, done_unclaimed.id
      )
    end

    it "still supports explicit ownership_scope=claimable param for backward compat" do
      teammate = Factories.user(email_address: "teammate@example.com")
      teammate_repo = Factories.repository(user: teammate, owner: "globex", name: "api")
      claimable_backlog = Factories.epic(user: teammate, repository: teammate_repo, state: "backlog", title: "Claimable backlog epic")
      claimable = Factories.epic(user: teammate, repository: teammate_repo, state: "ready", title: "Claimable epic")
      not_claimable = Factories.epic(user: teammate, repository: teammate_repo, owner: teammate, state: "ready", title: "Teammate epic")

      get "/api/v1/app/dashboard", params: { subject: "epic", ownership_scope: "claimable" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["items"].map { |item| item.fetch("id") }).to contain_exactly(claimable_backlog.id, claimable.id)
      expect(body["items"].find { |item| item.fetch("id") == claimable.id }.fetch("owner_badge")).to eq(
        "label" => "Claimable",
        "kind" => "claimable"
      )
      expect(body["items"].map { |item| item.fetch("id") }).not_to include(not_claimable.id)
    end

    it "supports team and per-user ownership scopes with useful badges" do
      teammate = Factories.user(email_address: "teammate@example.com", first_name: "Team", last_name: "Mate")
      teammate_repo = Factories.repository(user: teammate, owner: "globex", name: "api")
      mine = Factories.job_record(user: user, repository: repo, owner_user: user, issue_number: 30, issue_title: "Mine")
      theirs = Factories.job_record(user: teammate, repository: teammate_repo, owner_user: teammate, issue_number: 31, issue_title: "Theirs")

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

    it "falls back to the saved per-subject dashboard view" do
      user.update_dashboard_view!(subject: "job", view: "kanban")
      Factories.job_record(repository: repo, owner_user: user, issue_number: 91, issue_title: "Board item", state: "queued")

      get "/api/v1/app/dashboard", params: { subject: "job" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["view"]).to eq("kanban")
    end

    it "uses the built-in null-folder Epic view default" do
      get "/api/v1/app/dashboard", params: { subject: "epic" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["view"]).to eq("kanban")
    end

    it "uses the built-in landing queue sort default" do
      SmartFolder.ensure_builtins!
      folder = SmartFolder.find_by!(user_id: nil, subject_type: "job", name: "Landing queue")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("preferences", "sort")).to include("column" => "landing_queue_position", "direction" => "asc")
    end

    it "lets saved folder preferences override built-in defaults" do
      SmartFolder.ensure_builtins!
      folder = SmartFolder.find_by!(user_id: nil, subject_type: "job", name: "Landing queue")
      user.update_dashboard_folder_preferences!(
        subject: "job",
        smart_folder_id: folder.id,
        sort_column: "created_at",
        sort_direction: "desc"
      )

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("preferences", "sort")).to include("column" => "created_at", "direction" => "desc")
    end

    it "uses a saved folder view preference when the URL omits view" do
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Board jobs",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "queued" } ] }
      )
      user.update_dashboard_folder_preferences!(
        subject: "job",
        smart_folder_id: folder.id,
        view: "kanban"
      )

      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["view"]).to eq("kanban")
    end

    it "restores a saved dependencies view preference for a folder when the URL omits view" do
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Graph jobs",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "open" } ] }
      )
      user.update_dashboard_folder_preferences!(
        subject: "job",
        smart_folder_id: folder.id,
        view: "dependencies"
      )

      get "/api/v1/app/dashboard", params: { subject: "job", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["view"]).to eq("dependencies")
    end

    it "falls back to subject-level sort when a folder has no saved or built-in preference" do
      folder = SmartFolder.create!(
        user: user,
        subject_type: "job",
        name: "Running jobs",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "running" } ] }
      )
      user.update_dashboard_sort!(subject: "job", column: "started_at", direction: "asc")

      get "/api/v1/app/dashboard", params: { subject: "job", view: "list", smart_folder_id: folder.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("preferences", "sort")).to include("column" => "started_at", "direction" => "asc")
    end

    it "falls back to the saved smart folder when the URL omits smart_folder_id" do
      folder = SmartFolder.create!(
        user: user,
        subject_type: "epic",
        name: "Ready work",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "ready" } ] }
      )
      user.update_dashboard_smart_folder!(subject: "epic", smart_folder_id: folder.id)

      get "/api/v1/app/dashboard", params: { subject: "epic" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["active_smart_folder_id"]).to eq(folder.id)
    end

    it "lets the URL smart folder override the saved preference" do
      saved = SmartFolder.create!(
        user: user,
        subject_type: "epic",
        name: "Saved ready",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "ready" } ] }
      )
      requested = SmartFolder.create!(
        user: user,
        subject_type: "epic",
        name: "Requested backlog",
        kind: "user_defined",
        filter: { "and" => [ { "field" => "state", "op" => "is", "value" => "backlog" } ] }
      )
      user.update_dashboard_smart_folder!(subject: "epic", smart_folder_id: saved.id)

      get "/api/v1/app/dashboard", params: { subject: "epic", smart_folder_id: requested.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["active_smart_folder_id"]).to eq(requested.id)
    end
  end

  describe "PATCH /api/v1/app/dashboard/preferences" do
    it "updates dashboard sort, visible columns, Kanban lanes, view, and smart folder" do
      patch "/api/v1/app/dashboard/preferences",
            params: {
              subject: "jobs",
              sort_column: "started_at",
              sort_direction: "asc",
              visible_columns: %w[state repository],
              kanban_lanes: %w[queued running],
              view: "kanban",
              smart_folder_id: 7
            },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["message"]).to eq("Dashboard preferences updated.")
      preferences = user.reload.dashboard_preferences.fetch("jobs")
      expect(preferences).to include(
        "sort_column" => "started_at",
        "sort_direction" => "asc",
        "visible_columns" => %w[title state repository],
        "kanban_lanes" => %w[queued running],
        "last_view" => "kanban",
        "last_smart_folder_id" => "7"
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

    it "saves sort with an active smart folder to folder preferences" do
      patch "/api/v1/app/dashboard/preferences",
            params: {
              subject: "jobs",
              active_smart_folder_id: 42,
              sort_column: "started_at",
              sort_direction: "asc"
            },
            as: :json

      expect(response).to have_http_status(:ok)
      preferences = user.reload.dashboard_preferences.fetch("jobs")
      expect(preferences).to include("sort_column" => "created_at", "sort_direction" => "desc")
      expect(preferences.dig("folder_prefs", "42")).to eq(
        "sort_column" => "started_at",
        "sort_direction" => "asc"
      )
    end

    it "saves view without an active smart folder to subject preferences" do
      patch "/api/v1/app/dashboard/preferences",
            params: { subject: "jobs", view: "kanban" },
            as: :json

      expect(response).to have_http_status(:ok)
      preferences = user.reload.dashboard_preferences.fetch("jobs")
      expect(preferences.fetch("last_view")).to eq("kanban")
      expect(preferences.fetch("folder_prefs")).to eq({})
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

    it "approves app-authored jobs without trying to leave a self-review on GitHub" do
      AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
      installation = Factories.installation(user: user, account_login: "acme")
      repo.update!(auto_merge_enabled: true, installation: installation)
      job = Factories.job(repository: repo, issue_number: 10, pr_number: 660)
      job.update!(state: "implemented")
      client = instance_double(GithubClient)
      allow(AppEvents).to receive(:broadcast)
      allow(GithubClient).to receive(:for).with(repository: repo, user: user).and_return(client)
      allow(client).to receive(:pull_request)
        .with("acme/widgets", 660, bypass_cache: true)
        .and_return(Struct.new(:user).new(Struct.new(:login).new("operator-syrus[bot]")))
      expect(client).not_to receive(:create_pr_review)

      post "/api/v1/app/dashboard/jobs/bulk",
           params: { job_ids: [ job.id ], bulk_action: "approve" },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(job.reload).to be_approved
      expect(parse_body["message"]).to include("Approved 1 job in batch")
      expect(parse_body["message"]).not_to include("GitHub review failed")
      expect(parse_body["message"]).not_to include("GitHub reviews left")
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

    it "claims selected jobs for the current user" do
      first = Factories.job(repository: repo, issue_number: 1)
      second = Factories.job(repository: repo, issue_number: 2)
      allow(AppEvents).to receive(:broadcast)

      post "/api/v1/app/dashboard/jobs/bulk",
           params: { job_ids: [ first.id, second.id ], bulk_action: "claim" },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(first.reload.claimed_by_user).to eq(user)
      expect(second.reload.claimed_by_user).to eq(user)
      expect(first.claimed_at).to be_present
      expect(parse_body["message"]).to eq("Claimed 2 jobs.")
      expect(parse_body["affected_job_ids"]).to contain_exactly(first.id, second.id)
    end

    it "releases only the current user's selected claims" do
      teammate = Factories.user(email_address: "teammate@example.com")
      mine = Factories.job(repository: repo, issue_number: 1, claimed_by_user: user, claimed_at: Time.current)
      theirs = Factories.job(repository: repo, issue_number: 2, claimed_by_user: teammate, claimed_at: Time.current)
      allow(AppEvents).to receive(:broadcast)

      post "/api/v1/app/dashboard/jobs/bulk",
           params: { job_ids: [ mine.id, theirs.id ], bulk_action: "release_claim" },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(mine.reload.claimed_by_user).to be_nil
      expect(theirs.reload.claimed_by_user).to eq(teammate)
      expect(parse_body["message"]).to eq("Released 1 claim.")
      expect(parse_body["affected_job_ids"]).to eq([ mine.id ])
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

    it "rejects product-owner bulk starts" do
      user.update!(role: "product_owner")
      ready = Factories.epic(user: user, repository: repo, title: "Ready aqueduct", state: "ready")

      post "/api/v1/app/dashboard/epics/bulk",
           params: { epic_ids: [ ready.id ], bulk_action: "start" },
           as: :json

      expect(response).to have_http_status(:forbidden)
      expect(ready.reload).to be_ready
      expect(parse_body.dig("error", "message")).to eq("Product owners cannot advance Epics beyond backlog.")
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
