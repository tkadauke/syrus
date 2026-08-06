require "rails_helper"

RSpec.describe App::DashboardPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def call(params = {})
    described_class.call(user: user, params: ActionController::Parameters.new(params))
  end

  describe "provider availability" do
    it "exposes user-level provider availability with Codex usage windows" do
      user.update!(
        codex_usage_status: "ok",
        codex_usage_observed_at: Time.zone.parse("2026-07-31T14:00:00Z"),
        codex_usage_snapshot: {
          "remaining_percent" => 24.0,
          "primary" => { "label" => "5h", "remaining_percent" => 61.5, "used_percent" => 38.5, "reset_at" => "2026-07-31T18:00:00Z" },
          "secondary" => { "label" => "weekly", "remaining_percent" => 24.0, "used_percent" => 76.0, "reset_at" => "2026-08-07T12:00:00Z" }
        }
      )

      result = call(subject: "job", section: "chrome")

      expect(result.dig(:provider_availability, "codex")).to include(state: "available", open: false)
      expect(result.dig(:provider_availability, "codex", :usage, :windows, "five_hour")).to include(
        label: "5h",
        remaining_percent: 61.5
      )
      expect(result.dig(:provider_availability, "codex", :usage, :windows, "weekly")).to include(
        label: "weekly",
        remaining_percent: 24.0
      )
    end

    it "mirrors user-level provider availability onto job rows" do
      job = Factories.job_record(user: user, repository: repo, agent_provider: "claude")
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
      step = Step.create!(workflow: workflow, kind: "implement", position: 0, state: "failed")
      failed_run = Run.create!(
        job: job,
        user: user,
        step: step,
        trigger_kind: "initial",
        state: "failed",
        agent_provider: "claude",
        agent_outcome: "rate_limited",
        finished_at: Time.zone.parse("2026-07-31T14:00:00Z")
      )
      RunFailureClassification.create!(
        run: failed_run,
        classification: "rate_limited",
        retryable: true,
        confidence: 0.9,
        reason: "rate limit",
        classified_at: Time.current
      )

      result = call(subject: "job", section: "rows")
      item = result[:items].find { |row| row[:id] == job.id }

      expect(item[:provider_availability]).to include(
        provider: "claude",
        state: "rate_limited",
        open: true,
        usage_exhausted: false
      )
    end
  end

  describe "default inbox view" do
    # Builtins are seeded by the service on each call, but we need them available
    # for assertions before the second call, so ensure them explicitly.
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    let(:inbox_folder) { SmartFolder.find_builtin_by_attention("inbox") }

    it "reports the inbox SmartFolder's ID as active_smart_folder_id" do
      result = call(subject: "job", view: "list")
      expect(result[:active_smart_folder_id]).to eq(inbox_folder.id)
    end

    it "reads sort preferences from the inbox folder's slot (round-trip)" do
      # The frontend saves sort preferences keyed by active_smart_folder_id.
      # On the default inbox view that is inbox_folder.id, so we write there.
      user.update_dashboard_folder_preferences!(
        subject: "job",
        smart_folder_id: inbox_folder.id,
        sort_column: "started_at",
        sort_direction: "asc"
      )

      result = call(subject: "job", view: "list")

      # active_folder_key_for_prefs must resolve to inbox_folder.id so the
      # preference slot written above is actually read back here.
      expect(result[:preferences][:sort]).to include(column: "started_at", direction: "asc")
    end

    it "does not bleed inbox folder preferences into the key-null slot" do
      # Preferences saved under the inbox folder's numeric ID must not affect
      # reads keyed by "null" (explicit smart_folder_id=nil in the URL).
      user.update_dashboard_folder_preferences!(
        subject: "job",
        smart_folder_id: inbox_folder.id,
        sort_column: "started_at",
        sort_direction: "asc"
      )

      # An explicit smart_folder_id=nil in params means "no folder" — should
      # NOT see the inbox-keyed preference.
      result = call(subject: "job", view: "list", smart_folder_id: nil)

      default_column = User::DASHBOARD_SORT_DEFAULTS.fetch("job").fetch("column")
      expect(result[:preferences][:sort]).to include(column: default_column)
    end

    it "does not activate inbox default when a filter param is present" do
      result = call(subject: "job", view: "list", "q" => "state:running")
      # With a filter param, default_inbox_smart_folder? is false;
      # active_smart_folder should be nil (no inbox fallback).
      expect(result[:active_smart_folder_id]).to be_nil
    end

    it "includes folder-specific chrome fields in rows payloads" do
      user.update_dashboard_folder_preferences!(
        subject: "job",
        smart_folder_id: inbox_folder.id,
        sort_column: "started_at",
        sort_direction: "asc"
      )

      result = call(subject: "job", view: "list", section: "rows")

      expect(result[:active_smart_folder_id]).to eq(inbox_folder.id)
      expect(result[:filter]).to be_present
      expect(result[:preferences][:sort]).to include(column: "started_at", direction: "asc")
      expect(result.dig(:controls, :columns, :required)).to be_present
      expect(result).not_to have_key(:smart_folders)
    end
  end

  describe "priority sort" do
    let(:urgent_job) { Factories.job_record(user: user, repository: repo, priority: "urgent") }
    let(:high_job) { Factories.job_record(user: user, repository: repo, priority: "high") }
    let(:medium_job) { Factories.job_record(user: user, repository: repo, priority: "medium") }
    let(:low_job) { Factories.job_record(user: user, repository: repo, priority: "low") }

    before { [ urgent_job, high_job, medium_job, low_job ] }

    it "sorts ascending: urgent first, then high, medium, low" do
      result = call(subject: "job", sort_column: "priority", sort_direction: "asc")
      ids = result[:items].map { |j| j[:id] }
      expect(ids.index(urgent_job.id)).to be < ids.index(high_job.id)
      expect(ids.index(high_job.id)).to be < ids.index(medium_job.id)
      expect(ids.index(medium_job.id)).to be < ids.index(low_job.id)
    end

    it "sorts descending: low first, then medium, high, urgent" do
      result = call(subject: "job", sort_column: "priority", sort_direction: "desc")
      ids = result[:items].map { |j| j[:id] }
      expect(ids.index(low_job.id)).to be < ids.index(medium_job.id)
      expect(ids.index(medium_job.id)).to be < ids.index(high_job.id)
      expect(ids.index(high_job.id)).to be < ids.index(urgent_job.id)
    end

    it "exposes priority as a sortable column in controls" do
      result = call(subject: "job")
      expect(result[:controls][:sort_columns]).to include("priority")
    end

    it "exposes priority as an optional column" do
      result = call(subject: "job")
      optional_keys = result[:controls][:columns][:optional].map { |c| c[:key] }
      expect(optional_keys).to include("priority")
    end
  end

  describe "commits_behind_base column" do
    let(:far_behind_job) { Factories.job_record(user: user, repository: repo).tap { |j| j.update_columns(commits_behind_base: 55) } }
    let(:slightly_behind_job) { Factories.job_record(user: user, repository: repo).tap { |j| j.update_columns(commits_behind_base: 5) } }
    let(:current_job) { Factories.job_record(user: user, repository: repo).tap { |j| j.update_columns(commits_behind_base: 0) } }
    let(:unknown_job) { Factories.job_record(user: user, repository: repo) }

    before { [ far_behind_job, slightly_behind_job, current_job, unknown_job ] }

    it "serializes commits_behind_base in each job item" do
      result = call(subject: "job")
      item = result[:items].find { |j| j[:id] == far_behind_job.id }
      expect(item[:commits_behind_base]).to eq(55)
    end

    it "serializes nil for jobs with no commits_behind_base" do
      result = call(subject: "job")
      item = result[:items].find { |j| j[:id] == unknown_job.id }
      expect(item[:commits_behind_base]).to be_nil
    end

    it "exposes commits_behind_base as an optional column" do
      result = call(subject: "job")
      optional_keys = result[:controls][:columns][:optional].map { |c| c[:key] }
      expect(optional_keys).to include("commits_behind_base")
    end

    it "exposes commits_behind_base as a sortable column in controls" do
      result = call(subject: "job")
      expect(result[:controls][:sort_columns]).to include("commits_behind_base")
    end

    it "sorts ascending: lowest commits_behind_base first, nulls last" do
      result = call(subject: "job", sort_column: "commits_behind_base", sort_direction: "asc")
      ids = result[:items].map { |j| j[:id] }
      expect(ids.index(current_job.id)).to be < ids.index(slightly_behind_job.id)
      expect(ids.index(slightly_behind_job.id)).to be < ids.index(far_behind_job.id)
      expect(ids.index(far_behind_job.id)).to be < ids.index(unknown_job.id)
    end

    it "sorts descending: highest commits_behind_base first, nulls last" do
      result = call(subject: "job", sort_column: "commits_behind_base", sort_direction: "desc")
      ids = result[:items].map { |j| j[:id] }
      expect(ids.index(far_behind_job.id)).to be < ids.index(slightly_behind_job.id)
      expect(ids.index(slightly_behind_job.id)).to be < ids.index(current_job.id)
      expect(ids.index(current_job.id)).to be < ids.index(unknown_job.id)
    end
  end

  describe "deployment column" do
    let(:staging) { SyrusYml::DeploymentStage.new(name: "staging", label: "On Staging", tag: "staging", tag_pattern: nil) }
    let(:production) { SyrusYml::DeploymentStage.new(name: "production", label: "In Production", tag: "production", tag_pattern: nil) }

    before do
      allow(RepoDeploymentStagesReader).to receive(:for_repository).and_return(
        RepoDeploymentStagesReader::Result.new(stages: [ staging, production ], source: ".syrus.yml", note: nil)
      )
    end

    it "exposes deployment as an optional job column" do
      result = call(subject: "job")
      optional_keys = result[:controls][:columns][:optional].map { |c| c[:key] }

      expect(optional_keys).to include("deployment")
    end

    it "serializes the furthest configured deployment stage reached" do
      job = Factories.job_record(user: user, repository: repo, landed_sha: "abc123")
      job.deployment_stage_statuses.create!(stage_name: "staging", reached_at: Time.zone.parse("2026-07-30T12:00:00Z"))
      job.deployment_stage_statuses.create!(stage_name: "production", reached_at: Time.zone.parse("2026-07-30T13:00:00Z"))

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item[:latest_deployment_stage]).to eq(
        name: "production",
        label: "In Production",
        reached_at: "2026-07-30T13:00:00Z"
      )
    end

    it "serializes nil when deployment stages are configured but none are reached" do
      job = Factories.job_record(user: user, repository: repo, landed_sha: "abc123")

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(latest_deployment_stage: nil)
    end
  end

  describe "landing queue blocker job entries" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    let(:landing_queue_folder) { SmartFolder.find_builtin_by_attention("landing_queue") }
    let(:blocker_repo) { Factories.repository(user: user) }

    it "includes repository, latest workflow fields, and timestamps for blocker jobs in landing queue entries" do
      blocker_job = Factories.job_record(user: user, repository: blocker_repo, state: "implemented", issue_number: 20, issue_title: "Blocker")
      workflow = Workflow.create!(job: blocker_job, trigger_kind: "initial", state: "failed")

      approved_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      approved_job.approve!(via: "github_review")

      JobDependency.create!(job: approved_job, depends_on_job: blocker_job, source: "manual", created_by_user: user)
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id)
      entries = result.dig(:landing_queue, :entries)
      blocker_entry = entries&.flat_map { |e| e[:blocker_jobs] }&.find { |b| b[:id] == blocker_job.id }

      expect(blocker_entry).to include(
        id: blocker_job.id,
        repository: hash_including(id: blocker_repo.id, slug: blocker_repo.slug),
        latest_workflow_id: workflow.id,
        latest_workflow_state: "failed",
        latest_workflow_trigger_kind: "initial",
        created_at: blocker_job.created_at.iso8601
      )
    end

    it "reports a merge-train start blocker as a blocked reason" do
      AppSetting.current.update!(merge_train_enabled: true)
      epic = Factories.epic(user: user, repository: repo, state: "in_progress")
      first = Factories.job_record(user: user, repository: repo, epic: epic, state: "landing", pr_number: 101)
      tip = Factories.job_record(user: user, repository: repo, epic: epic, state: "landing", pr_number: 102)
      train = MergeTrain.create!(epic: epic, repository: repo, base_branch: repo.default_branch)
      MergeTrainMember.create!(merge_train: train, job: first, position: 0)
      MergeTrainMember.create!(merge_train: train, job: tip, position: 1)
      Workflow.create!(
        job: tip,
        trigger_kind: "merge_train",
        state: "queued",
        artifacts: { "merge_train_id" => train.id, "start_blocked_reason" => "urgent_job_active" }
      )

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id)
      items = result[:items].index_by { |item| item[:id] }

      expect(items.fetch(first.id)[:landing_queue_blocked_reason]).to eq("Merge train queued: urgent job active")
      expect(items.fetch(first.id)[:landing_queue_wait_reason]).to be_nil
      expect(items.fetch(tip.id)[:landing_queue_blocked_reason]).to eq("Merge train queued: urgent job active")
      expect(items.fetch(tip.id)[:landing_queue_wait_reason]).to be_nil
    end

    it "reports ordinary Epic merge-train participation as neutral queue status" do
      AppSetting.current.update!(merge_train_enabled: true)
      repo.update!(auto_merge_enabled: true)
      epic = Factories.epic(user: user, repository: repo, state: "in_progress")
      child = Factories.job_record(user: user, repository: repo, epic: epic, state: "implemented", pr_number: 101)
      child.approve!(via: "github_review")
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id)
      item = result[:items].find { |row| row[:id] == child.id }

      expect(item[:landing_queue_blocked_reason]).to be_nil
      expect(item[:landing_queue_wait_reason]).to eq({ "key" => "waiting_epic_merge_train" })
      expect(child.reload.landing_queue_blocked_reason).to eq({ "key" => "waiting_epic_merge_train" })
    end

    it "sorts eligible landing queue rows before blocked Epic merge-train rows when Queue is ascending" do
      AppSetting.current.update!(merge_train_enabled: true)
      repo.update!(auto_merge_enabled: true)

      older = Factories.job_record(user: user, repository: repo, state: "implemented", pr_number: 101)
      older.approve!(via: "github_review")
      older.update!(approved_at: 30.minutes.ago)

      epic = Factories.epic(user: user, repository: repo, state: "in_progress")
      epic_child = Factories.job_record(user: user, repository: repo, epic: epic, state: "implemented", pr_number: 102)
      epic_child.approve!(via: "github_review")
      epic_child.update!(approved_at: 20.minutes.ago)

      newer = Factories.job_record(user: user, repository: repo, state: "implemented", pr_number: 103)
      newer.approve!(via: "github_review")
      newer.update!(approved_at: 10.minutes.ago)

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id)

      expect(result[:items].map { |item| item[:id] }).to eq([ older.id, newer.id, epic_child.id ])
      expect(result[:items].map { |item| item[:landing_queue_position] }).to eq([ 1, 2, nil ])
      expect(result[:items].map { |item| item[:landing_queue_entry_key] }).to eq([ "job:#{older.id}", "job:#{newer.id}", "epic:#{epic.id}" ])
      expect(epic_child.reload.landing_queue_position).to be_nil
      expect(epic_child.landing_queue_entry_position).to eq(2)
    end

    it "sorts blocked landing queue rows before eligible rows when Queue is descending" do
      AppSetting.current.update!(merge_train_enabled: true)
      repo.update!(auto_merge_enabled: true)

      older = Factories.job_record(user: user, repository: repo, state: "implemented", pr_number: 101)
      older.approve!(via: "github_review")
      older.update!(approved_at: 30.minutes.ago)

      epic = Factories.epic(user: user, repository: repo, state: "in_progress")
      epic_child = Factories.job_record(user: user, repository: repo, epic: epic, state: "implemented", pr_number: 102)
      epic_child.approve!(via: "github_review")
      epic_child.update!(approved_at: 20.minutes.ago)

      newer = Factories.job_record(user: user, repository: repo, state: "implemented", pr_number: 103)
      newer.approve!(via: "github_review")
      newer.update!(approved_at: 10.minutes.ago)

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id, sort_column: "landing_queue_position", sort_direction: "desc")

      expect(result[:items].map { |item| item[:id] }).to eq([ epic_child.id, newer.id, older.id ])
      expect(result[:items].map { |item| item[:landing_queue_position] }).to eq([ nil, 2, 1 ])
      expect(result[:items].map { |item| item[:landing_queue_entry_key] }).to eq([ "epic:#{epic.id}", "job:#{newer.id}", "job:#{older.id}" ])
    end

    it "applies eligible-first Queue sorting before paginating" do
      blocked_repo = Factories.repository(user: user, auto_merge_enabled: false)
      repo.update!(auto_merge_enabled: true)
      blocked_jobs = Array.new(described_class::PER_PAGE) do |index|
        Factories.job_record(user: user, repository: blocked_repo, state: "implemented", pr_number: 200 + index).tap do |job|
          job.approve!(via: "github_review")
          job.update!(approved_at: (described_class::PER_PAGE - index + 1).minutes.ago)
        end
      end
      visible_first = Factories.job_record(user: user, repository: repo, state: "implemented", pr_number: 300)
      visible_first.approve!(via: "github_review")
      visible_first.update!(approved_at: Time.current)

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id, sort_column: "landing_queue_position", sort_direction: "asc")

      expect(result[:items].first[:id]).to eq(visible_first.id)
      expect(result[:items].first[:landing_queue_position]).to eq(1)
      expect(result[:items].map { |item| item[:id] }).to include(blocked_jobs.first.id)
    end

    it "falls back to landing state drift when a landing row has no active workflow or train" do
      job = Factories.job_record(user: user, repository: repo, state: "landing", pr_number: 101)
      Workflow.create!(job: job, trigger_kind: "auto_merge", state: "failed")

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id)
      item = result[:items].find { |row| row[:id] == job.id }

      expect(item[:landing_queue_blocked_reason]).to eq("Landing state drift: no active workflow")
      expect(item[:landing_queue_wait_reason]).to be_nil
    end

    it "shows required landing queue columns with neutral queue status copy" do
      result = call(subject: "job", smart_folder_id: landing_queue_folder.id)
      required = result[:controls][:columns][:required]

      expect(required.map { |column| column[:key] }).to include("landing_queue_wait_reason")
      expect(required.find { |column| column[:key] == "landing_queue_wait_reason" }[:title]).to eq("Queue status")
      expect(required.map { |column| column[:key] }).not_to include("landing_queue_blocked_reason")
    end
  end

  describe "commits_behind_base in job items" do
    it "includes commits_behind_base in the job item payload" do
      job = Factories.job_record(user: user, repository: repo)
      job.update_columns(commits_behind_base: 25)

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(commits_behind_base: 25)
    end

    it "includes nil commits_behind_base when not yet computed" do
      job = Factories.job_record(user: user, repository: repo)

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(commits_behind_base: nil)
    end
  end

  describe "blocked folder blocked_reason" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    let(:blocked_folder) { SmartFolder.find_builtin_by_attention("blocked") }

    it "returns nil blocked_reason outside the blocked folder" do
      job = Factories.job_record(user: user, repository: repo)
      job.update_columns(pr_mergeable: false)

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item[:blocked_reason]).to be_nil
    end

    it "shows required columns including blocked_reason when viewing blocked folder" do
      result = call(subject: "job", smart_folder_id: blocked_folder.id)
      required_keys = result[:controls][:columns][:required].map { |c| c[:key] }

      expect(required_keys).to include("blocked_reason")
      expect(required_keys).not_to include("landing_queue_position")
    end

    it "does not count ordinary Epic merge-train waits as blocked" do
      AppSetting.current.update!(merge_train_enabled: true)
      repo.update!(auto_merge_enabled: true)
      epic = Factories.epic(user: user, repository: repo, state: "in_progress")
      child = Factories.job_record(user: user, repository: repo, epic: epic, state: "implemented", pr_number: 101)
      child.approve!(via: "github_review")
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

      result = call(subject: "job", smart_folder_id: blocked_folder.id)

      expect(result[:total]).to eq(0)
      expect(result[:items]).to be_empty
    end

    it "reports pr_not_mergeable for jobs with pr_mergeable false" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      job.update_columns(pr_mergeable: false)

      result = call(subject: "job", smart_folder_id: blocked_folder.id)
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item[:blocked_reason]).to eq({ key: "pr_not_mergeable" })
    end

    it "prefers landing_queue_blocked_reason over pr_not_mergeable" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      job.update_columns(
        pr_mergeable: false,
        landing_queue_blocked_reason: { key: "pr_checks_failing", params: { slug: "JOB-99" } }
      )

      result = call(subject: "job", smart_folder_id: blocked_folder.id)
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item[:blocked_reason]).to eq({ "key" => "pr_checks_failing", "params" => { "slug" => "JOB-99" } })
    end

    it "shows waiting-for-job reason for dependency-blocked jobs" do
      blocker = Factories.job_record(user: user, repository: repo, state: "running")
      blocked_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      JobDependency.create!(job: blocked_job, depends_on_job: blocker, source: "manual", created_by_user: user)

      result = call(subject: "job", smart_folder_id: blocked_folder.id)
      item = result[:items].find { |i| i[:id] == blocked_job.id }

      expect(item[:blocked_reason]).to eq({ key: "waiting_to_merge", params: { slug: "JOB-#{blocker.id}" } })
    end

    it "does not show dep reason when the only dependency is already satisfied" do
      blocker = Factories.job_record(user: user, repository: repo, state: "closed", closure_reason: "pr_merged")
      # Job is in the blocked folder due to pr_mergeable:false, not the dep (which is satisfied)
      blocked_job = Factories.job_record(user: user, repository: repo, state: "running")
      blocked_job.update_columns(pr_mergeable: false)
      JobDependency.create!(job: blocked_job, depends_on_job: blocker, source: "manual", created_by_user: user)

      result = call(subject: "job", smart_folder_id: blocked_folder.id)
      item = result[:items].find { |i| i[:id] == blocked_job.id }

      # satisfied dep should not be shown; pr_not_mergeable takes effect instead
      expect(item[:blocked_reason]).to eq({ key: "pr_not_mergeable" })
    end
  end

  describe "start_blocked_reason on job items" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    it "includes start_blocked_reason from the queued workflow's artifacts" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: {
          "start_blocked_reason" => "stack_fan_in_base_unavailable",
          "start_blocked_details" => {
            "kind" => "fan_in_base_unavailable",
            "dependencies" => [ { "slug" => "JOB-1574" } ]
          }
        }
      )

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(
        start_blocked_reason: "stack_fan_in_base_unavailable",
        start_blocked_details: include(
          "kind" => "fan_in_base_unavailable",
          "dependencies" => [ { "slug" => "JOB-1574" } ]
        )
      )
    end

    it "includes nil start_blocked_reason when no blocked workflow exists" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(job: job, trigger_kind: "initial", state: "queued")

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(start_blocked_reason: nil)
    end

    it "shows running workflows with deferred progress as paused instead of in progress" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        artifacts: {
          "pause_reason" => "workflow_admission_budget",
          "start_blocked_reason" => "workflow_admission_budget",
          "start_blocked_next_check_at" => 5.minutes.from_now.iso8601
        }
      )

      rows = call(subject: "job", section: "rows")
      item = rows[:items].find { |i| i[:id] == job.id }
      expect(item[:summary_state]).to eq("paused")
      expect(item[:start_blocked_reason]).to eq("workflow_admission_budget")

      paused_folder = SmartFolder.find_builtin_by_attention("paused")
      in_progress_folder = SmartFolder.find_builtin_by_attention("in_progress")

      paused = call(subject: "job", smart_folder_id: paused_folder.id, section: "rows")
      in_progress = call(subject: "job", smart_folder_id: in_progress_folder.id, section: "rows")

      expect(paused[:items].map { |row| row[:id] }).to include(job.id)
      expect(in_progress[:items].map { |row| row[:id] }).not_to include(job.id)
    end

    it "keeps admission-blocked landing workflows in landing queue instead of paused" do
      job = Factories.job_record(
        user: user,
        repository: repo,
        state: "landing",
        pr_number: 77,
        branch_name: "syrus/issue-77",
        approved_at: 1.minute.ago
      )
      Workflow.create!(
        job: job,
        trigger_kind: "auto_merge",
        state: "queued",
        artifacts: {
          "start_blocked_reason" => "landing start blocked: workflow admission budget",
          "start_blocked_next_check_at" => 5.minutes.from_now.iso8601
        }
      )
      paused_folder = SmartFolder.find_builtin_by_attention("paused")
      landing_folder = SmartFolder.find_builtin_by_attention("landing_queue")

      paused = call(subject: "job", smart_folder_id: paused_folder.id, section: "rows")
      landing = call(subject: "job", smart_folder_id: landing_folder.id, section: "rows")

      expect(paused[:items].map { |row| row[:id] }).not_to include(job.id)
      expect(landing[:items].map { |row| row[:id] }).to include(job.id)
    end
  end

  describe "blocked_count on queued smart folder" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    it "includes blocked_count on the queued folder when blocked jobs exist" do
      queued_job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: queued_job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: { "start_blocked_reason" => "urgent_job_active" }
      )

      result = call(subject: "job")
      queued_folder = result[:smart_folders].find { |f| f[:key] == "queued" }

      expect(queued_folder[:blocked_count]).to eq(1)
    end

    it "excludes blocked queued jobs owned by other users in team scope" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "acme", name: "other-widgets")
      mine = Factories.job_record(user: user, repository: repo, state: "queued")
      theirs = Factories.job_record(user: other_user, repository: other_repo, state: "queued", owner_user: other_user)

      [ mine, theirs ].each do |job|
        Workflow.create!(
          job: job,
          trigger_kind: "initial",
          state: "queued",
          artifacts: { "start_blocked_reason" => "urgent_job_active" }
        )
      end

      result = call(subject: "job", ownership_scope: "team")
      queued_folder = result[:smart_folders].find { |f| f[:key] == "queued" }

      expect(queued_folder[:blocked_count]).to eq(1)
    end

    it "includes blocked_count of zero when no blocked queued jobs exist" do
      Factories.job_record(user: user, repository: repo, state: "queued")

      result = call(subject: "job")
      queued_folder = result[:smart_folders].find { |f| f[:key] == "queued" }

      expect(queued_folder[:blocked_count]).to eq(0)
    end

    it "does not include blocked_count on non-queued folders" do
      result = call(subject: "job")
      inbox_folder = result[:smart_folders].find { |f| f[:key] == "inbox" }

      expect(inbox_folder).not_to have_key(:blocked_count)
    end
  end

  describe "smart folder count caching" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    it "caches stable sidebar counts as one snapshot and recomputes volatile counts" do
      cache_store = ActiveSupport::Cache::MemoryStore.new
      fetch_keys = []
      computed_folder_ids = []

      allow(Rails).to receive(:cache).and_return(cache_store)
      allow(cache_store).to receive(:fetch).and_wrap_original do |method, key, **options, &block|
        fetch_keys << key
        method.call(key, **options, &block)
      end
      allow_any_instance_of(described_class).to receive(:smart_folder_count_uncached).and_wrap_original do |method, folder|
        computed_folder_ids << folder.id
        method.call(folder)
      end

      first = call(subject: "job", section: "chrome")
      second = call(subject: "job", section: "chrome")
      active_folder_id = first[:active_smart_folder_id]
      volatile_ids = SmartFolder.builtins(:job)
                                .select { |folder| folder.builtin_key.in?(%w[in_progress paused queued landing_queue]) }
                                .map(&:id)
      stable_counted_ids = SmartFolder.for_subject("job")
                                      .where("user_id IS NULL OR user_id = ?", user.id)
                                      .where.not(id: volatile_ids)
                                      .select { |folder| !folder.builtin? || folder.visibility.in?([ :always, :when_present ]) || folder.id == active_folder_id }
                                      .map(&:id)
      stable_uncounted_ids = SmartFolder.for_subject("job")
                                        .where("user_id IS NULL OR user_id = ?", user.id)
                                        .where.not(id: volatile_ids + stable_counted_ids)
                                        .pluck(:id)

      expect(second[:smart_folders].map { |folder| [ folder[:id], folder[:count] ] }).to eq(
        first[:smart_folders].map { |folder| [ folder[:id], folder[:count] ] }
      )
      expect(fetch_keys.select { |key| Array(key).first == "dashboard_smart_folder_counts" }.size).to eq(2)
      expect(fetch_keys).not_to include(a_collection_including("dashboard_smart_folder_count"))
      expect(computed_folder_ids.tally).to include(stable_counted_ids.index_with(1))
      expect(computed_folder_ids.tally).to include(volatile_ids.index_with(2))
      expect(computed_folder_ids & stable_uncounted_ids).to be_empty
    end
  end

  describe "start_blocked filter" do
    it "filters job items to queued workflows with a start blocked reason" do
      blocked_job = Factories.job_record(user: user, repository: repo, state: "queued")
      unblocked_job = Factories.job_record(user: user, repository: repo, state: "queued")
      Workflow.create!(
        job: blocked_job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: { "start_blocked_reason" => "main_branch_broken" }
      )
      Workflow.create!(job: unblocked_job, trigger_kind: "initial", state: "queued")

      result = call(subject: "job", start_blocked: "1")

      expect(result[:items].map { |item| item[:id] }).to contain_exactly(blocked_job.id)
    end
  end

  describe "job_epic_json counts" do
    let(:other_user) { Factories.user }
    let(:epic) { Factories.epic(user: user, repository: repo) }

    it "reports jobs_count as the true epic total even when some jobs are excluded by the ownership filter" do
      job1 = Factories.job_record(user: user, repository: repo, epic: epic, owner_user: user, issue_number: 101)
      job2 = Factories.job_record(user: user, repository: repo, epic: epic, owner_user: user, issue_number: 102)
      job3 = Factories.job_record(user: user, repository: repo, epic: epic, owner_user: other_user, issue_number: 103)

      result = call(subject: "job", scope: "mine")

      visible_ids = result[:items].map { |j| j[:id] }
      expect(visible_ids).to include(job1.id, job2.id)
      expect(visible_ids).not_to include(job3.id)

      item = result[:items].find { |j| j[:id] == job1.id }
      # jobs_count must reflect all 3 epic jobs, not just the 2 visible in the "mine" scope
      expect(item.dig(:epic, :jobs_count)).to eq(3)
    end

    it "reports landed_jobs_count counting only pr_merged and external_pr_merged closure reasons" do
      open_job = Factories.job_record(user: user, repository: repo, epic: epic, owner_user: user, issue_number: 101)
      Factories.job_record(user: user, repository: repo, epic: epic, owner_user: user,
                           issue_number: 102, state: "closed", closure_reason: "pr_merged")
      Factories.job_record(user: user, repository: repo, epic: epic, owner_user: user,
                           issue_number: 103, state: "closed", closure_reason: "external_pr_merged")
      Factories.job_record(user: user, repository: repo, epic: epic, owner_user: user,
                           issue_number: 104, state: "closed", closure_reason: "no_changes")

      result = call(subject: "job", scope: "mine")
      item = result[:items].find { |j| j[:id] == open_job.id }

      expect(item.dig(:epic, :jobs_count)).to eq(4)
      # no_changes does not count as landed; only pr_merged and external_pr_merged do
      expect(item.dig(:epic, :landed_jobs_count)).to eq(2)
    end
  end
end
