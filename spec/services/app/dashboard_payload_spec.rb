require "rails_helper"

RSpec.describe App::DashboardPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def call(params = {})
    described_class.call(user: user, params: ActionController::Parameters.new(params))
  end

  def backfill_work_unit(workflow, state: workflow.state, blocked_reason: nil, blocked_details: nil, blocked_until: nil)
    attach_work_unit(
      workflow,
      state: state,
      blocked_reason: blocked_reason,
      blocked_details: blocked_details,
      blocked_until: blocked_until
    )
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

  describe "latest_workflow_started_at on job items" do
    it "exposes the started_at of the job's latest workflow, not the job's own started_at" do
      job = Factories.job_record(user: user, repository: repo, started_at: Time.zone.parse("2026-07-31T10:00:00Z"))
      Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: Time.zone.parse("2026-07-31T11:30:00Z"))

      result = call(subject: "job", section: "rows")
      item = result[:items].find { |row| row[:id] == job.id }

      expect(item[:latest_workflow_started_at]).to eq("2026-07-31T11:30:00Z")
    end

    it "is nil when the latest workflow has not started yet" do
      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(job: job, trigger_kind: "initial", state: "queued")

      result = call(subject: "job", section: "rows")
      item = result[:items].find { |row| row[:id] == job.id }

      expect(item[:latest_workflow_started_at]).to be_nil
    end
  end

  describe "active workflow trigger on job items" do
    it "uses preloaded active workflow trigger data for running jobs" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      workflow = Workflow.create!(job: job, trigger_kind: "chat_feedback", state: "running", started_at: Time.current)
      backfill_work_unit(workflow)

      allow_any_instance_of(Job).to receive(:active_workflow_trigger_kind).and_raise("unexpected fallback query")

      result = call(subject: "job", section: "rows")
      item = result[:items].find { |row| row[:id] == job.id }

      expect(item[:active_workflow_trigger_kind]).to eq("chat_feedback")
    end

    it "keeps closed jobs closed even when diagnostic WorkUnits look blocked" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "running", started_at: Time.current)
      backfill_work_unit(workflow, state: "blocked", blocked_reason: "admission_control")
      job.update!(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)

      payload = described_class.new(user: user, params: ActionController::Parameters.new(subject: "job", section: "rows"))

      expect(payload.send(:summary_state, job)).to eq("closed")
    end
  end

  describe "start-blocked row data" do
    it "only scans start-blocked workflow artifacts for the current job page" do
      visible = Factories.job_record(user: user, repository: repo, state: "queued")
      unrelated = Factories.job_record(user: user, repository: repo, state: "queued")
      visible_workflow = Workflow.create!(
        job: visible,
        trigger_kind: "initial",
        state: "queued",
        artifacts: { "start_blocked_reason" => "admission_control" }
      )
      backfill_work_unit(visible_workflow, state: "blocked", blocked_reason: "admission_control")
      Workflow.create!(
        job: unrelated,
        trigger_kind: "initial",
        state: "queued",
        artifacts: { "start_blocked_reason" => "main_branch_broken" }
      )

      payload = described_class.new(user: user, params: ActionController::Parameters.new(subject: "job", section: "rows"))
      payload.instance_variable_set(:@current_jobs, [ visible ])

      result = payload.send(:start_blocked_data_by_job_id)

      expect(result.keys).to eq([ visible.id ])
      expect(result.dig(visible.id, :reason)).to eq("admission_control")
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

    it "looks up the default inbox folder only once per call, not once per consumer" do
      allow(SmartFolder).to receive(:find_builtin_by_attention).and_call_original

      call(subject: "job", view: "list", section: "full")

      expect(SmartFolder).to have_received(:find_builtin_by_attention).once
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

    it "reports a bundle-other-job-count for a blocker that's landing as part of a job bundle" do
      a = Factories.job_record(user: user, repository: blocker_repo, state: "landing", issue_number: 21, issue_title: "Bundle member A", pr_number: 201)
      b = Factories.job_record(user: user, repository: blocker_repo, state: "landing", issue_number: 22, issue_title: "Bundle member B", pr_number: 202)
      train = MergeTrain.create!(repository: blocker_repo, base_branch: blocker_repo.default_branch, priority: "medium")
      MergeTrainMember.create!(merge_train: train, job: a, position: 0)
      MergeTrainMember.create!(merge_train: train, job: b, position: 1)

      approved_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      approved_job.approve!(via: "github_review")
      JobDependency.create!(job: approved_job, depends_on_job: a, source: "manual", created_by_user: user)
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id)
      entries = result.dig(:landing_queue, :entries)
      blocker_entry = entries&.flat_map { |e| e[:blocker_jobs] }&.find { |blocker| blocker[:id] == a.id }

      expect(blocker_entry).to include(bundle_other_job_count: 1)
      expect(blocker_entry).not_to have_key(:epic_id)
    end

    it "reports a merge-train start blocker as a blocked reason" do
      AppSetting.current.update!(merge_train_enabled: true)
      epic = Factories.epic(user: user, repository: repo, state: "in_progress")
      first = Factories.job_record(user: user, repository: repo, epic: epic, state: "landing", pr_number: 101)
      tip = Factories.job_record(user: user, repository: repo, epic: epic, state: "landing", pr_number: 102)
      train = MergeTrain.create!(epic: epic, repository: repo, base_branch: repo.default_branch)
      MergeTrainMember.create!(merge_train: train, job: first, position: 0)
      MergeTrainMember.create!(merge_train: train, job: tip, position: 1)
      workflow = Workflow.create!(
        job: tip,
        trigger_kind: "merge_train",
        state: "queued",
        artifacts: { "merge_train_id" => train.id, "start_blocked_reason" => "urgent_job_active" }
      )
      backfill_work_unit(workflow, state: "blocked", blocked_reason: "urgent_job_active")

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id)
      items = result[:items].index_by { |item| item[:id] }

      expect(items.fetch(first.id)[:landing_queue_blocked_reason]).to eq("Merge train queued: urgent job active")
      expect(items.fetch(first.id)[:landing_queue_wait_reason]).to be_nil
      expect(items.fetch(tip.id)[:landing_queue_blocked_reason]).to eq("Merge train queued: urgent job active")
      expect(items.fetch(tip.id)[:landing_queue_wait_reason]).to be_nil
    end

    it "reports a WorkUnit-owned merge-train blocker without relying on workflow artifacts" do
      AppSetting.current.update!(merge_train_enabled: true)
      epic = Factories.epic(user: user, repository: repo, state: "in_progress")
      first = Factories.job_record(user: user, repository: repo, epic: epic, state: "landing", pr_number: 101)
      tip = Factories.job_record(user: user, repository: repo, epic: epic, state: "landing", pr_number: 102)
      train = MergeTrain.create!(epic: epic, repository: repo, base_branch: repo.default_branch)
      MergeTrainMember.create!(merge_train: train, job: first, position: 0)
      MergeTrainMember.create!(merge_train: train, job: tip, position: 1)
      intent = WorkIntent.create!(
        kind: "merge_train",
        state: "requested",
        repository: repo,
        scope_type: "epic",
        scope_id: epic.id,
        actor: user,
        source_type: "spec"
      )
      workflow = Workflow.create!(
        job: tip,
        trigger_kind: "merge_train",
        state: "succeeded",
        artifacts: { "merge_train_id" => train.id }
      )
      unit = WorkUnit.create!(
        work_intent: intent,
        kind: "merge_train",
        state: "blocked",
        repository: repo,
        scope_type: "epic",
        scope_id: epic.id,
        workflow: workflow,
        blocked_reason: "urgent_job_active"
      )
      unit.work_unit_members.create!(job: first, role: "primary")
      unit.work_unit_members.create!(job: tip, role: "member")

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

    it "reports ordinary epicless job-bundle participation as neutral queue status" do
      Feature.create!(slug: "epicless_job_bundling", category: "Labs", name: "Epicless Job bundling", enabled: true)
      repo.update!(auto_merge_enabled: true)
      first = Factories.job_record(user: user, repository: repo, state: "implemented", pr_number: 101)
      second = Factories.job_record(user: user, repository: repo, state: "implemented", pr_number: 102)
      [ first, second ].each { |job| job.approve!(via: "github_review") }
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

      result = call(subject: "job", smart_folder_id: landing_queue_folder.id)
      item = result[:items].find { |row| row[:id] == second.id }

      expect(item[:landing_queue_blocked_reason]).to be_nil
      expect(item[:landing_queue_wait_reason]).to eq({ "key" => "waiting_epicless_bundle" })
      expect(second.reload.landing_queue_blocked_reason).to eq({ "key" => "waiting_epicless_bundle" })
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
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

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
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

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
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

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

      expect(item[:blocked_reason]).to eq({ key: "waiting_to_merge", params: { slug: blocker.slug } })
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
      workflow = Workflow.create!(
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
      backfill_work_unit(
        workflow,
        state: "blocked",
        blocked_reason: "stack_fan_in_base_unavailable",
        blocked_details: {
          "kind" => "fan_in_base_unavailable",
          "dependencies" => [ { "slug" => "JOB-1574" } ]
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

    it "includes start_blocked_next_check_at from the WorkUnit block" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      next_check = 5.minutes.from_now.iso8601
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: {
          "start_blocked_reason" => "urgent_job_active",
          "start_blocked_at" => 10.minutes.ago.iso8601,
          "start_blocked_next_check_at" => next_check,
          "start_blocked_count" => 3
        }
      )
      backfill_work_unit(workflow, state: "blocked", blocked_reason: "urgent_job_active", blocked_until: Time.zone.parse(next_check))

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(
        start_blocked_next_check_at: next_check,
        start_blocked_count: nil
      )
    end

    it "includes nil for start_blocked_next_check_at and start_blocked_count when absent from artifacts" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: { "start_blocked_reason" => "urgent_job_active" }
      )
      backfill_work_unit(workflow, state: "blocked", blocked_reason: "urgent_job_active")

      result = call(subject: "job")
      item = result[:items].find { |i| i[:id] == job.id }

      expect(item).to include(
        start_blocked_next_check_at: nil,
        start_blocked_count: nil
      )
    end

    it "shows running workflows with deferred progress as paused instead of in progress" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        artifacts: {
          "pause_reason" => "workflow_admission_budget",
          "start_blocked_reason" => "workflow_admission_budget",
          "start_blocked_next_check_at" => 5.minutes.from_now.iso8601
        }
      )
      backfill_work_unit(
        workflow,
        state: "blocked",
        blocked_reason: "admission_control",
        blocked_details: { "start_blocked_reason" => "workflow_admission_budget" }
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

    it "shows blocked work units as paused without requiring legacy workflow artifacts" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)
      workflow.update!(state: "running")
      next_check = 5.minutes.from_now
      workflow.work_unit.block!(
        reason: "admission_control",
        blocked_until: next_check,
        details: { "reason" => "worker_host_pressure_high", "source" => "spec" }
      )

      rows = call(subject: "job", section: "rows")
      item = rows[:items].find { |i| i[:id] == job.id }
      expect(item[:summary_state]).to eq("paused")
      expect(item[:start_blocked_reason]).to eq("admission_control")
      expect(item[:start_blocked_next_check_at]).to eq(next_check.iso8601)
      expect(item[:start_blocked_details]).to include("reason" => "worker_host_pressure_high")

      paused_folder = SmartFolder.find_builtin_by_attention("paused")
      in_progress_folder = SmartFolder.find_builtin_by_attention("in_progress")

      paused = call(subject: "job", smart_folder_id: paused_folder.id, section: "rows")
      in_progress = call(subject: "job", smart_folder_id: in_progress_folder.id, section: "rows")

      expect(paused[:items].map { |row| row[:id] }).to include(job.id)
      expect(in_progress[:items].map { |row| row[:id] }).not_to include(job.id)
    end

    it "shows blocked WorkUnits with running Runs as in progress" do
      job = Factories.job_record(user: user, repository: repo, state: "approved")
      workflow = WorkUnits::Launcher.instantiate(kind: "ci_failure", job: job)
      workflow.update!(state: "running")
      workflow.work_unit.block!(reason: "resource_safety", details: { "source" => "spec" })
      step = workflow.steps.create!(kind: "grader", position: 1, state: "running")
      step.runs.create!(job: job, user: user, trigger_kind: workflow.trigger_kind, state: "running")

      rows = call(subject: "job", section: "rows")
      item = rows[:items].find { |i| i[:id] == job.id }

      expect(item[:summary_state]).to eq("running")
      expect(item[:start_blocked_reason]).to eq("resource_safety")

      paused_folder = SmartFolder.find_builtin_by_attention("paused")
      in_progress_folder = SmartFolder.find_builtin_by_attention("in_progress")

      paused = call(subject: "job", smart_folder_id: paused_folder.id, section: "rows")
      in_progress = call(subject: "job", smart_folder_id: in_progress_folder.id, section: "rows")

      expect(paused[:items].map { |row| row[:id] }).not_to include(job.id)
      expect(in_progress[:items].map { |row| row[:id] }).to include(job.id)
    end

    it "does not treat queued Runs as active dashboard work" do
      job = Factories.job_record(user: user, repository: repo, state: "failed", failure_count: 1)
      queued_workflow = Workflow.create!(job: job, trigger_kind: "retry", state: "queued", created_at: 3.minutes.ago)
      queued_step = queued_workflow.steps.create!(kind: "prepare", position: 1, state: "queued")
      queued_step.runs.create!(job: job, user: user, trigger_kind: "retry", state: "queued", created_at: 3.minutes.ago)
      failed_workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "failed",
        failure_count: 1,
        failure_reason: "transient failure",
        created_at: 2.minutes.ago,
        finished_at: 2.minutes.ago
      )
      failed_step = failed_workflow.steps.create!(kind: "implement", position: 1, state: "failed")
      failed_step.runs.create!(
        job: job,
        user: user,
        trigger_kind: "initial",
        state: "failed",
        finished_at: 2.minutes.ago
      )

      rows = call(subject: "job", section: "rows")
      item = rows[:items].find { |i| i[:id] == job.id }

      expect(item[:summary_state]).to eq("failed")
      expect(item[:retry_state]).to include(
        retryable: true,
        state_label: "Retryable failure"
      )
    end

    it "does not show stale pause artifacts as paused while WorkUnit-owned work is active" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      owner = Factories.job_record(user: user, repository: repo, state: "running")
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        artifacts: {
          "pause_reason" => "workflow_admission_budget",
          "start_blocked_reason" => "workflow_admission_budget"
        }
      )
      workflow = WorkUnits::Launcher.instantiate(kind: "merge_train", job: owner)
      workflow.update!(state: "running")
      workflow.work_unit.work_unit_members.create!(job: job, role: "member")

      rows = call(subject: "job", section: "rows")
      item = rows[:items].find { |i| i[:id] == job.id }

      expect(item[:summary_state]).to eq("running")
      expect(item[:start_blocked_reason]).to be_nil
    end

    it "shows failed jobs with active repair WorkUnits as repairing" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow = WorkUnits::Launcher.instantiate(kind: "ci_failure", job: job)
      workflow.update!(state: "running")
      workflow.work_unit.mark_running!

      rows = call(subject: "job", section: "rows")
      item = rows[:items].find { |i| i[:id] == job.id }

      expect(item).to include(
        state: "failed",
        summary_state: "repairing",
        active_workflow_trigger_kind: "ci_failure"
      )
      expect(item[:active_repair_work]).to include(
        kind: "ci_failure",
        workflow_id: workflow.id,
        workflow_state: "running",
        work_unit_id: workflow.work_unit.id,
        work_unit_state: "running"
      )

      in_progress_folder = SmartFolder.find_builtin_by_attention("in_progress")
      just_failed_folder = SmartFolder.find_builtin_by_attention("just_failed")
      in_progress = call(subject: "job", smart_folder_id: in_progress_folder.id, section: "rows")
      just_failed = call(subject: "job", smart_folder_id: just_failed_folder.id, section: "rows")

      expect(in_progress[:items].map { |row| row[:id] }).to include(job.id)
      expect(just_failed[:items].map { |row| row[:id] }).not_to include(job.id)
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
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "auto_merge",
        state: "queued",
        artifacts: {
          "start_blocked_reason" => "landing start blocked: workflow admission budget",
          "start_blocked_next_check_at" => 5.minutes.from_now.iso8601
        }
      )
      backfill_work_unit(
        workflow,
        state: "blocked",
        blocked_reason: "admission_control",
        blocked_details: { "start_blocked_reason" => "landing start blocked: workflow admission budget" }
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
      workflow = Workflow.create!(
        job: queued_job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: { "start_blocked_reason" => "urgent_job_active" }
      )
      backfill_work_unit(workflow, state: "blocked", blocked_reason: "urgent_job_active")

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
        workflow = Workflow.create!(
          job: job,
          trigger_kind: "initial",
          state: "queued",
          artifacts: { "start_blocked_reason" => "urgent_job_active" }
        )
        backfill_work_unit(workflow, state: "blocked", blocked_reason: "urgent_job_active")
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

  describe "epics_claimable smart folder visibility on single-user instances" do
    it "hides the claimable folder when there is only one user" do
      result = call(subject: "epic")

      expect(result[:smart_folders].map { |f| f[:key] }).not_to include("epics_claimable")
    end

    it "shows the claimable folder when there are multiple users" do
      Factories.user

      result = call(subject: "epic")

      expect(result[:smart_folders].map { |f| f[:key] }).to include("epics_claimable")
    end

    it "still shows the claimable folder when it is the currently active folder, even for a single user" do
      SmartFolder.ensure_builtins_for_subject!("epic")
      claimable_folder = SmartFolder.for_subject("epic").builtin.find { |f| f.builtin_key == "epics_claimable" }

      result = call(subject: "epic", smart_folder_id: claimable_folder.id)

      expect(result[:smart_folders].map { |f| f[:key] }).to include("epics_claimable")
    end
  end

  describe "fast built-in smart folder counts" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    it "keeps the optimized inbox count aligned with the generic inbox filter" do
      inbox_folder = SmartFolder.find_builtin_by_attention("inbox")
      implemented = Factories.job_record(user: user, repository: repo, state: "implemented")
      failed = Factories.job_record(user: user, repository: repo, state: "failed")
      running = Factories.job_record(user: user, repository: repo, state: "implemented")
      workflow = Workflow.create!(job: running, trigger_kind: "initial", state: "running")
      backfill_work_unit(workflow)
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "acme", name: "other")
      Factories.job_record(user: other_user, owner_user: other_user, repository: other_repo, state: "implemented")

      result = call(subject: "job", section: "chrome")
      count = result.fetch(:smart_folders).find { |folder| folder[:key] == "inbox" }.fetch(:count)
      generic_count = Jobs::Filter.from_tree(inbox_folder.filter, user: user)
                                  .apply(App::DashboardPayload.new(user: user, params: ActionController::Parameters.new(subject: "job")).send(:jobs_base_scope))
                                  .count

      expect(count).to eq(generic_count)
      expect(count).to eq(2)
      expect([ implemented, failed ].map(&:id)).to all(be_present)
    end
  end

  describe "smart folder count caching" do
    before { SmartFolder.ensure_builtins_for_subject!("job") }

    it "caches stable sidebar counts as one snapshot and recomputes volatile counts" do
      cache_store = ActiveSupport::Cache::MemoryStore.new
      fetch_keys = []
      computed_folder_ids = []

      allow(SyrusVersion).to receive(:current).and_return("revision-that-must-not-enter-folder-count-cache")
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
      expect(fetch_keys.flatten).not_to include("revision-that-must-not-enter-folder-count-cache")
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
      workflow = Workflow.create!(
        job: blocked_job,
        trigger_kind: "initial",
        state: "queued",
        artifacts: { "start_blocked_reason" => "main_branch_broken" }
      )
      backfill_work_unit(
        workflow,
        state: "blocked",
        blocked_reason: "main_branch_health",
        blocked_details: { "start_blocked_reason" => "main_branch_broken" }
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

  describe "untagged_issues chrome field" do
    it "returns a zero total and no repositories when nothing has untagged open issues" do
      repo.update_columns(untagged_open_issue_count: 0)

      result = call(subject: "job")

      expect(result[:untagged_issues]).to eq(total: 0, repositories: [])
    end

    it "aggregates the total across repositories and includes a per-repository breakdown" do
      repo.update_columns(untagged_open_issue_count: 5)
      other_repo = Factories.repository(user: user, untagged_open_issue_count: 7)
      zero_repo = Factories.repository(user: user, untagged_open_issue_count: 0)

      result = call(subject: "job")

      expect(result[:untagged_issues][:total]).to eq(12)
      breakdown = result[:untagged_issues][:repositories]
      expect(breakdown.map { |entry| entry[:id] }).to contain_exactly(repo.id, other_repo.id)
      expect(breakdown.map { |entry| entry[:id] }).not_to include(zero_repo.id)

      repo_entry = breakdown.find { |entry| entry[:id] == repo.id }
      expect(repo_entry).to eq(
        id: repo.id,
        slug: repo.slug,
        count: 5,
        issues_path: "/repositories/#{repo.id}?tab=github_issues"
      )
    end

    it "excludes archived repositories even when they have a stale untagged issue count" do
      repo.update_columns(untagged_open_issue_count: 3)
      archived = Factories.repository(user: user, untagged_open_issue_count: 4, archived_at: Time.current)

      result = call(subject: "job")

      expect(result[:untagged_issues][:total]).to eq(3)
      expect(result[:untagged_issues][:repositories].map { |entry| entry[:id] }).not_to include(archived.id)
    end

    it "respects the same active_repositories_scope used by the rest of the chrome payload (team-wide, active-only)" do
      repo.update_columns(untagged_open_issue_count: 2)
      teammate = Factories.user
      teammate_repo = Factories.repository(user: teammate, untagged_open_issue_count: 6)

      result = call(subject: "job")

      # Dashboard repository visibility is team-wide (same scoping `counts` and
      # `landing_queue` chrome fields already use), not restricted to repos this
      # user personally connected.
      breakdown_ids = result[:untagged_issues][:repositories].map { |entry| entry[:id] }
      expect(breakdown_ids).to contain_exactly(repo.id, teammate_repo.id)
      expect(result[:untagged_issues][:total]).to eq(8)
    end
  end

  describe "simple-mode Preview & Approve row action" do
    before do
      AppSetting.current.update!(mode: "simple", mode_configured_at: Time.current)
      allow(Syrus::Plugin::PreviewProvider).to receive(:configured?).and_return(true)
    end

    it "exposes can_approve and can_start_preview plus their paths for an implemented standalone job" do
      job = Factories.job_record(user: user, repository: repo, owner_user: user, state: "implemented")

      result = call(subject: "job", section: "rows")
      item = result[:items].find { |row| row[:id] == job.id }

      expect(item[:can_approve]).to be(true)
      expect(item[:can_start_preview]).to be(true)
      expect(item[:paths]).to include(
        app_approve_path: "/api/v1/app/jobs/#{job.id}/approve",
        app_preview_path: "/api/v1/app/jobs/#{job.id}/preview",
        app_preview_logs_path: "/api/v1/app/jobs/#{job.id}/preview/logs"
      )
    end

    it "is false outside simple mode even for an otherwise-eligible job" do
      AppSetting.current.update!(mode: "advanced")
      job = Factories.job_record(user: user, repository: repo, owner_user: user, state: "implemented")

      result = call(subject: "job", section: "rows")
      item = result[:items].find { |row| row[:id] == job.id }

      expect(item[:can_start_preview]).to be(false)
    end

    it "is false when no preview provider is configured for the repository" do
      allow(Syrus::Plugin::PreviewProvider).to receive(:configured?).and_return(false)
      job = Factories.job_record(user: user, repository: repo, owner_user: user, state: "implemented")

      result = call(subject: "job", section: "rows")
      item = result[:items].find { |row| row[:id] == job.id }

      expect(item[:can_start_preview]).to be(false)
    end

    it "can_start_preview is false once the job is no longer previewable" do
      job = Factories.job_record(user: user, repository: repo, owner_user: user, state: "queued")

      result = call(subject: "job", section: "rows")
      item = result[:items].find { |row| row[:id] == job.id }

      expect(item[:can_start_preview]).to be(false)
    end

    it "hides can_approve for a legacy Epic child job, which keeps reviewing through the Epic rollup flow" do
      epic = Factories.epic(user: user, repository: repo)
      job = Factories.job_record(user: user, repository: repo, epic: epic, owner_user: user, state: "implemented")

      result = call(subject: "job", section: "rows")
      item = result[:items].find { |row| row[:id] == job.id }

      expect(item[:can_approve]).to be(false)
    end
  end
end
