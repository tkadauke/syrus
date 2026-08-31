require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::JobDetailPayload, :ci_only do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    described_class.build(job: job, user: user)
  end

  def workflows_payload_for(job)
    described_class.workflows(job: job, user: user)
  end

  def capture_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA"

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def attach_work_unit(workflow, member_jobs:, kind: workflow.trigger_kind, state: "running", blocked_reason: nil)
    primary = member_jobs.first
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: primary.repository,
      scope_type: primary.epic_id.present? ? "epic" : "job",
      scope_id: primary.epic_id.presence || primary.id,
      actor: primary.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: state,
      repository: primary.repository,
      scope_type: intent.scope_type,
      scope_id: intent.scope_id,
      workflow: workflow,
      blocked_reason: blocked_reason,
      blocked_details: blocked_reason ? { "source" => "spec" } : {}
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end
  describe "#workflows_json" do
    before do
      AppSetting.current.update!(show_work_unit_debug: true)
    end

    it "includes the active work intent in the default job detail payload" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "initial")

      payload = payload_for(job)

      expect(payload.fetch(:current_intent)).to include(
        id: unit.work_intent_id,
        kind: "initial",
        label: "Initial implementation",
        state: "requested",
        scope_type: "job",
        scope_id: job.id,
        execution_label: nil,
        execution_status: "running"
      )
    end

    it "includes the blocked WorkUnit reason as the intent execution label" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "queued")
      unit = attach_work_unit(workflow, member_jobs: [ job ], kind: "ci_failure", state: "blocked", blocked_reason: "admission_control")

      payload = workflows_payload_for(job)

      expect(payload.fetch(:current_intent)).to include(
        id: unit.work_intent_id,
        execution_status: "blocked",
        execution_label: "Admission control"
      )
    end

    it "prefers running WorkUnit attempts over newer blocked attempts in the active work card" do
      job = Factories.job_record(user: user, repository: repo)
      running_workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "running", created_at: 5.minutes.ago)
      running_unit = attach_work_unit(running_workflow, member_jobs: [ job ], kind: "ci_failure", state: "running")
      blocked_workflow = Workflow.create!(job: job, trigger_kind: "rebase", state: "queued")
      blocked_unit = attach_work_unit(blocked_workflow, member_jobs: [ job ], kind: "rebase", state: "blocked", blocked_reason: "resource_safety")

      payload = payload_for(job)

      expect(payload.fetch(:active_work)).to include(
        id: running_unit.id,
        kind: "ci_failure",
        state: "running",
        workflow_id: running_workflow.id
      )
      expect(workflows_payload_for(job).fetch(:work_units).map { |unit| unit[:id] }).to include(blocked_unit.id)
    end

    it "includes a waiting job-scoped intent even when no work unit exists yet" do
      job = Factories.job_record(user: user, repository: repo)
      intent = WorkIntent.create!(
        kind: "initial",
        state: "waiting",
        repository: repo,
        scope_type: "job",
        scope_id: job.id,
        actor: user,
        wait_reason: "dependency",
        wait_details: { "blocked_by_job_ids" => [ 9 ] },
        source_type: "spec"
      )

      payload = payload_for(job)

      expect(payload.fetch(:active_work)).to be_nil
      expect(payload.fetch(:current_intent)).to include(
        id: intent.id,
        kind: "initial",
        label: "Initial implementation",
        state: "waiting",
        wait_reason: "dependency",
        wait_label: "Dependency",
        wait_details: include("blocked_by_job_ids" => [ 9 ]),
        execution_status: "blocked"
      )

      workflows_payload = workflows_payload_for(job)

      expect(workflows_payload.fetch(:current_intent)).to include(
        id: intent.id,
        kind: "initial",
        label: "Initial implementation",
        state: "waiting",
        wait_reason: "dependency",
        wait_label: "Dependency",
        wait_details: include("blocked_by_job_ids" => [ 9 ]),
        execution_status: "blocked"
      )
    end

    it "does not present stale work-unit debug state as current work after a job closes" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "failed")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "ci_failure", state: "failed")
      WorkIntent.create!(
        kind: "ci_failure",
        state: "requested",
        repository: repo,
        scope_type: "job",
        scope_id: job.id,
        actor: user,
        source_type: "spec"
      )
      job.update!(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)

      payload = payload_for(job)
      workflows_payload = workflows_payload_for(job)

      expect(payload.fetch(:current_intent)).to be_nil
      expect(payload.fetch(:active_work)).to be_nil
      expect(payload.fetch(:work_units)).to be_empty
      expect(workflows_payload.fetch(:current_intent)).to be_nil
      expect(workflows_payload.fetch(:work_units)).to be_empty
    end

    it "does not present active-looking WorkUnit state as current work after a job closes" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "running")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "ci_failure", state: "blocked", blocked_reason: "admission_control")
      job.update!(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)

      payload = payload_for(job)

      expect(payload.dig(:job, :summary_state)).to eq("closed")
      expect(payload.fetch(:active_work)).to be_nil
      expect(payload.fetch(:work_units)).to be_empty
    end

    it "includes a waiting epic-scoped intent for member jobs before a work unit exists" do
      epic = Factories.epic(user: user, repository: repo)
      job = Factories.job_record(user: user, repository: repo, epic: epic)
      intent = WorkIntent.create!(
        kind: "merge_train",
        state: "waiting",
        repository: repo,
        scope_type: "epic",
        scope_id: epic.id,
        actor: user,
        wait_reason: "epic_not_ready",
        wait_details: { "pending_job_ids" => [ job.id ] },
        source_type: "spec"
      )

      payload = workflows_payload_for(job)

      expect(payload.fetch(:current_intent)).to include(
        id: intent.id,
        kind: "merge_train",
        label: "Epic merge-train",
        state: "waiting",
        scope_type: "epic",
        scope_id: epic.id,
        wait_reason: "epic_not_ready",
        wait_label: "Epic not ready",
        wait_details: include("pending_job_ids" => [ job.id ]),
        execution_status: "blocked"
      )
    end

    it "includes work units involving the job even when the workflow is attached to another job" do
      epic = Factories.epic(user: user, repository: repo)
      first = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 101)
      second = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 102)
      workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
      unit = attach_work_unit(workflow, member_jobs: [ first, second ], kind: "merge_train")

      payload = workflows_payload_for(second)

      expect(payload.fetch(:workflows)).to be_empty
      expect(payload.fetch(:work_units)).to contain_exactly(
        include(
          id: unit.id,
          kind: "merge_train",
          label: "Epic merge-train",
          state: "running",
          workflow_id: workflow.id,
          workflow_trigger_kind: "merge_train",
          workflow_state: "running",
          workflow_attached_job_id: first.id,
          member_role: "member",
          scope_type: "epic",
          scope_id: epic.id,
          workflow: nil
        )
      )
    end

    it "labels bundle-backed merge train landing steps as job bundle landings" do
      first = Factories.job_record(user: user, repository: repo, issue_number: 101)
      second = Factories.job_record(user: user, repository: repo, issue_number: 102)
      workflow = Workflow.create!(job: first, trigger_kind: "merge_train", state: "running")
      Step.create!(workflow: workflow, kind: "merge_train_land", position: 1)
      Step.create!(workflow: workflow, kind: "merge_train_land_after_rebase", position: 2)
      attach_work_unit(workflow, member_jobs: [ first, second ], kind: "job_bundle")

      workflow_payload = workflows_payload_for(first).fetch(:workflows).first
      names_by_kind = workflow_payload.fetch(:steps).to_h { |step| [ step.fetch(:kind), step.fetch(:display_name) ] }

      expect(names_by_kind).to include(
        "merge_train_land" => "Land job bundle",
        "merge_train_land_after_rebase" => "Land job bundle after rebase"
      )
    end

    it "keeps Epic wording for Epic merge train landing steps" do
      epic = Factories.epic(user: user, repository: repo)
      job = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 101)
      workflow = Workflow.create!(job: job, trigger_kind: "merge_train", state: "running")
      Step.create!(workflow: workflow, kind: "merge_train_land", position: 1)
      attach_work_unit(workflow, member_jobs: [ job ], kind: "merge_train")

      workflow_payload = workflows_payload_for(job).fetch(:workflows).first
      expect(workflow_payload.fetch(:steps).first.fetch(:display_name)).to eq("Land Epic")
    end

    it "includes parent and preemption relationships for active WorkUnit diagnostics" do
      parent_workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", state: "running")
      parent = attach_work_unit(parent_workflow, member_jobs: [ job ], kind: "auto_merge")
      child_job = Factories.job_record(user: user, repository: repo, issue_number: 102)
      child_workflow = Workflow.create!(job: child_job, trigger_kind: "landing_validation", state: "queued")
      child = attach_work_unit(child_workflow, member_jobs: [ child_job ], kind: "landing_validation", state: "blocked")
      child.update!(
        parent_work_unit: parent,
        preemption_reason: "terminal_parent_work_unit",
        preempted_by_work_unit: parent
      )

      payload = workflows_payload_for(child_job)

      expect(payload.fetch(:work_units)).to contain_exactly(
        include(
          id: child.id,
          parent_work_unit_id: parent.id,
          parent_work_unit_kind: "auto_merge",
          parent_work_unit_label: "Auto-merge",
          preemption_reason: "terminal_parent_work_unit",
          preempted_by_work_unit_id: parent.id,
          preempted_by_work_unit_kind: "auto_merge",
          preempted_by_work_unit_label: "Auto-merge"
        )
      )
    end

    it "renders WorkUnit-owned direct workflows in the regular workflow list without nesting them under WorkUnits" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "running")
      run = Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running",
        started_at: 2.minutes.ago,
        last_heartbeat_at: 1.minute.ago
      )
      WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: "grader_side_effect",
        severity: "low",
        title: "needs attention"
      )
      SpawnedProcess.create!(
        kind: "agent",
        command: "claude --print",
        workdir: "/tmp/repo",
        hostname: "worker-1",
        pid: 4321,
        started_at: 1.minute.ago,
        run: run,
        workflow: workflow
      )
      attach_work_unit(workflow, member_jobs: [ job ], kind: "initial")

      payload = workflows_payload_for(job)
      workflow_payload = payload.fetch(:workflows).first
      nested_step = workflow_payload.fetch(:steps).first
      nested_run = nested_step.fetch(:runs).first

      expect(payload.fetch(:workflows).map { |entry| entry[:id] }).to eq([ workflow.id ])
      expect(payload.fetch(:work_units).map { |unit| unit[:workflow] }).to eq([ nil ])
      expect(payload.fetch(:workflows_pagination)).to include(
        total_workflows: 1,
        total_pages: 1,
        first_item: 1,
        last_item: 1
      )
      expect(workflow_payload.fetch(:steps).map { |entry| entry[:kind] }).to include("implement")
      expect(nested_step.fetch(:warnings)).to include(include(kind: "grader_side_effect", title: "needs attention"))
      expect(nested_run).to include(id: run.id, state: "running", can_stop: true)
      expect(nested_run.fetch(:active_process)).to include(
        kind: "agent",
        command: "claude --print",
        hostname: "worker-1",
        pid: 4321
      )
    end

    it "omits historical terminal WorkUnits from the job detail debug panel" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "failed")
      Step.create!(workflow: workflow, kind: "analyze_and_fix", position: 1, state: "failed")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "ci_failure", state: "failed")

      payload = workflows_payload_for(job)

      expect(payload.fetch(:workflows).map { |entry| entry[:id] }).to eq([ workflow.id ])
      expect(payload.fetch(:work_units)).to be_empty
    end

    it "keeps WorkUnit workflow graphs out of the default job detail response" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      Step.create!(workflow: workflow, kind: "implement", position: 1, state: "running")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "initial")

      payload = payload_for(job)

      expect(payload.dig(:active_work, :workflow)).to be_nil
      expect(payload.dig(:work_units, 0, :workflow)).to be_nil
    end

    it "does not call the legacy workflow navigation helper while building the job detail shell" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      Step.create!(workflow: workflow, kind: "implement", position: 1, state: "running")
      attach_work_unit(workflow, member_jobs: [ job ], kind: "initial")

      expect(App::WorkflowNavigation).not_to receive(:path)

      payload = payload_for(job)

      expect(payload.dig(:workflows_pagination, :total_workflows)).to eq(1)
    end

    it "renders step state from the latest run projection while preserving drift diagnostics" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "queued")
      Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running",
        started_at: 2.minutes.ago,
        last_heartbeat_at: 1.minute.ago
      )

      payload = workflows_payload_for(job)
      step_payload = payload.fetch(:workflows).first.fetch(:steps).first

      expect(step_payload).to include(
        kind: "implement",
        state: "running",
        persisted_state: "queued",
        display_status: "running"
      )
    end

    it "keeps legacy workflows without WorkUnit ownership in the fallback workflow list" do
      job = Factories.job_record(user: user, repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      Step.create!(workflow: workflow, kind: "implement", position: 1, state: "running")

      payload = workflows_payload_for(job)

      expect(payload.fetch(:work_units)).to be_empty
      expect(payload.fetch(:workflows).map { |entry| entry[:id] }).to eq([ workflow.id ])
    end

    it "keeps terminal WorkUnit-owned workflows in the regular paginated workflow list without duplicating them as attempts" do
      job = Factories.job_record(user: user, repository: repo)
      51.times do |index|
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded", created_at: index.minutes.ago)
        Step.create!(workflow: workflow, kind: "implement", position: 1, state: "succeeded")
        attach_work_unit(workflow, member_jobs: [ job ], kind: "initial", state: "succeeded")
      end

      payload = workflows_payload_for(job)

      expect(payload.fetch(:work_units)).to be_empty
      expect(payload.fetch(:workflows).size).to eq(App::WorkflowNavigation::PER_PAGE)
      expect(payload.fetch(:workflows_pagination)).to include(total_workflows: 51)
    end

    it "includes generic WorkflowWarning rows on the owning step, redacted" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial")
      step = Step.create!(workflow: workflow, kind: "grader", position: 1)
      pending_warning = WorkflowWarnings.record!(
        workflow: workflow,
        step: step,
        kind: "grader_side_effect",
        severity: "medium",
        title: "leaked https://x-access-token:abc123@github.com/acme/widgets.git",
        evidence: { "command" => "curl https://x-access-token:abc123@github.com/acme/widgets.git" },
        suggested_prompt: "fix it"
      )
      dismissed_warning = WorkflowWarnings.record!(workflow: workflow, step: step, kind: "grader_side_effect", title: "already handled")
      dismissed_warning.dismiss!

      workflow_payload = workflows_payload_for(job).fetch(:workflows).first
      step_payload = workflow_payload.fetch(:steps).first
      warnings_by_id = step_payload[:warnings].index_by { |w| w[:id] }

      expect(step_payload[:warnings].size).to eq(2)
      expect(warnings_by_id[pending_warning.id]).to include(
        kind: "grader_side_effect",
        severity: "medium",
        state: "pending",
        created_job_id: nil
      )
      expect(warnings_by_id[pending_warning.id][:title]).not_to include("abc123")
      expect(warnings_by_id[pending_warning.id][:evidence]["command"]).not_to include("abc123")
      expect(warnings_by_id[dismissed_warning.id][:state]).to eq("dismissed")
    end

    it "bounds serialized steps per workflow and keeps workflow failure classification" do
      stub_const("App::JobDetailPayload::WorkflowSerializers::MAX_STEPS_PER_WORKFLOW", 3)
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")

      5.times do |index|
        state = index.zero? ? "failed" : "succeeded"
        step = Step.create!(
          workflow: workflow,
          kind: "grader",
          position: index + 1,
          state: state,
          finished_at: (5 - index).minutes.ago
        )
        run = Run.create!(
          job: job,
          step: step,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: state,
          finished_at: (5 - index).minutes.ago
        )
        next unless index.zero?

        RunFailureClassification.create!(
          run: run,
          classification: "grader_failure",
          retryable: true,
          confidence: 0.9,
          reason: "rspec failed",
          classified_at: Time.current
        )
      end

      workflow_payload = workflows_payload_for(job).fetch(:workflows).first

      expect(workflow_payload).to include(
        steps_total: 5,
        steps_displayed: 3,
        steps_truncated: true
      )
      expect(workflow_payload.fetch(:steps).map { |step| step[:position] }).to eq([ 3, 4, 5 ])
      expect(workflow_payload.dig(:failure_classification, :classification)).to eq("grader_failure")
    end

    it "bounds serialized run history per step while preserving active runs" do
      stub_const("App::JobDetailPayload::WorkflowSerializers::MAX_RUNS_PER_STEP", 2)
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "grader", position: 1, state: "running")

      active_run = Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running",
        created_at: 10.minutes.ago,
        started_at: 10.minutes.ago
      )
      Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude", state: "failed", created_at: 8.minutes.ago, finished_at: 8.minutes.ago)
      Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude", state: "failed", created_at: 6.minutes.ago, finished_at: 6.minutes.ago)
      recent_succeeded = Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude", state: "succeeded", created_at: 2.minutes.ago, finished_at: 2.minutes.ago)
      recent_failed = Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude", state: "failed", created_at: 1.minute.ago, finished_at: 1.minute.ago)

      step_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0)

      expect(step_payload).to include(
        runs_total: 5,
        runs_displayed: 3,
        runs_truncated: true
      )
      expect(step_payload.fetch(:runs).map { |run| run[:id] }).to eq([ active_run.id, recent_succeeded.id, recent_failed.id ])
    end

    it "does not query command spans or spawned processes once per run" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")

      3.times do |index|
        step = Step.create!(workflow: workflow, kind: "grader", position: index, state: "running")
        run = Run.create!(
          job: job,
          step: step,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: "running",
          started_at: (index + 2).minutes.ago
        )
        SpawnedProcess.create!(
          kind: "grader",
          command: "bin/rspec",
          workdir: "/tmp/repo",
          hostname: "worker-#{index}",
          started_at: (index + 1).minutes.ago,
          run: run,
          workflow: workflow
        )
        run.command_spans.create!(
          job: job,
          workflow: workflow,
          step: step,
          sequence: index + 1,
          name: "rspec #{index}",
          command_excerpt: "bin/rspec",
          started_at: (index + 1).minutes.ago,
          hostname: "worker-#{index}"
        )
      end

      queries = capture_sql { payload_for(job) }

      expect(queries.grep(/FROM [`"]?command_spans[`"]? WHERE [`"]?command_spans[`"]?.[`"]?run_id[`"]? =/i)).to be_empty
      expect(queries.grep(/FROM [`"]?spawned_processes[`"]? WHERE [`"]?spawned_processes[`"]?.[`"]?run_id[`"]? =/i)).to be_empty
    end

    it "does not load full run diff text for workflow rows" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded")
      step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "succeeded")
      Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "succeeded",
        agent_diff: "a" * 1024,
        step_agent_diff: "b" * 2048
      )

      queries = []
      payload = nil
      callback = lambda do |_name, _started, _finished, _id, sql_payload|
        next if sql_payload[:cached] || sql_payload[:name] == "SCHEMA"

        queries << sql_payload[:sql]
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        payload = workflows_payload_for(job)
      end

      run_payload = payload.dig(:workflows, 0, :steps, 0, :runs, 0)
      expect(run_payload).to include(
        agent_diff_present: true,
        agent_diff_bytes: 1024,
        step_agent_diff_present: true,
        step_agent_diff_bytes: 2048
      )

      run_selects = queries.select { |sql| sql.match?(/FROM [`"]?runs[`"]?/i) }
      expect(run_selects.grep(/SELECT\s+[`"]?runs[`"]?\.\*/i)).to be_empty
    end

    it "loads workflow failure classifications in bulk" do
      job = Factories.job_record(repository: repo)

      3.times do |index|
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed", created_at: (3 - index).minutes.ago)
        step = Step.create!(workflow: workflow, kind: "grader", position: 1, state: "failed")
        run = Run.create!(
          job: job,
          step: step,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: "failed",
          finished_at: (3 - index).minutes.ago
        )
        RunFailureClassification.create!(
          run: run,
          classification: "grader_failure",
          retryable: true,
          confidence: 0.9,
          reason: "rspec failed #{index}",
          classified_at: Time.current
        )
      end

      queries = capture_sql { workflows_payload_for(job) }

      per_workflow_failed_run_queries = queries.grep(/FROM [`"]?runs[`"]?.*WHERE .*[`"]?steps[`"]?\.[`"]?workflow_id[`"]? =/im)
      expect(per_workflow_failed_run_queries).to be_empty
    end

    it "includes the active spawned process for running runs" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "running")
      run = Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running",
        started_at: 2.minutes.ago,
        last_heartbeat_at: 1.minute.ago
      )
      finished = SpawnedProcess.create!(
        kind: "prepare",
        command: "old command",
        workdir: "/tmp/old",
        hostname: "worker-1",
        started_at: 3.minutes.ago,
        finished_at: 2.minutes.ago,
        run: run,
        workflow: workflow
      )
      active = SpawnedProcess.create!(
        kind: "prepare",
        command: "bundle exec rspec",
        workdir: "/tmp/repo",
        hostname: "worker-2",
        pid: 1234,
        started_at: 1.minute.ago,
        last_chunk_at: 30.seconds.ago,
        wall_timeout_s: 600,
        silent_timeout_s: 120,
        run: run,
        workflow: workflow
      )

      active_process = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0, :active_process)

      expect(active_process).to include(
        id: active.id,
        kind: "prepare",
        command: "bundle exec rspec",
        workdir: "/tmp/repo",
        hostname: "worker-2",
        pid: 1234,
        wall_timeout_s: 600,
        silent_timeout_s: 120
      )
      expect(active_process[:id]).not_to eq(finished.id)
    end

    it "redacts GitHub credentials from active process and worker health process payloads" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
      step = Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "running")
      run = Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "running",
        started_at: 2.minutes.ago
      )
      SpawnedProcess.create!(
        kind: "git",
        command: "git fetch https://x-access-token:ghp_jobdetail@github.com/acme/widgets.git",
        workdir: "/tmp/repo",
        hostname: "worker-2",
        pid: 1234,
        started_at: 1.minute.ago,
        run: run,
        workflow: workflow
      )

      payload = workflows_payload_for(job)
      serialized = JSON.generate(payload)
      active_process = payload.dig(:workflows, 0, :steps, 0, :runs, 0, :active_process)

      expect(active_process[:command]).to eq("git fetch https://x-access-token:[REDACTED]@github.com/acme/widgets.git")
      expect(serialized).not_to include("ghp_jobdetail")
      expect(serialized).not_to include("x-access-token:ghp_")
    end

    it "omits per-run worker health correlation from the default workflow payload" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded", worker_hostname: "worker-1")
      step = Step.create!(workflow: workflow, kind: "grader", position: 0, state: "succeeded", details: { "name" => "rspec" })
      Run.create!(
        job: job,
        step: step,
        trigger_kind: "initial",
        agent_provider: "claude",
        state: "succeeded",
        started_at: 10.minutes.ago,
        finished_at: 1.minute.ago
      )
      WorkerHostHealthSample.create!(
        hostname: "worker-1",
        role: "worker",
        version: "abc123",
        observed_at: 5.minutes.ago,
        cpu_pressure_some: 52.0
      )

      run_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

      expect(run_payload).not_to have_key(:worker_health_correlation)
    end

    it "serializes only workflow artifact fields needed by the detail UI" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: {
          "summary" => "Done",
          "iterations" => [ { "name" => "rspec", "output" => "large" } ],
          "coverage" => {
            "summary" => { "lines_pct" => 90.0 },
            "files" => { "app.rb" => { "lines_pct" => 90.0 } },
            "diff_annotations" => { "app.rb" => { "1" => "covered" } },
            "pr_comment_body" => "large markdown"
          }
        }
      )

      artifacts = workflows_payload_for(job).dig(:workflows, 0, :artifacts)

      expect(artifacts).to include("summary" => "Done")
      expect(artifacts).not_to have_key("iterations")
      expect(artifacts.dig("coverage", "summary")).to eq("lines_pct" => 90.0)
      expect(artifacts["coverage"]).not_to have_key("diff_annotations")
      expect(artifacts["coverage"]).not_to have_key("pr_comment_body")
    end

    describe "run can_resume" do
      def failed_run_with_session(job, workflow)
        step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "failed")
        run = Run.create!(
          job: job,
          step: step,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: "failed",
          finished_at: 5.minutes.ago
        )
        ProviderSession.create!(
          resumable: run,
          provider: "claude",
          session_id: "claude-thread",
          transcript_jsonl: "{}\n"
        )
        run
      end

      it "is true for a failed run with a captured session when no other run is active" do
        job = Factories.job_record(repository: repo)
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
        failed_run_with_session(job, workflow)

        run_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

        expect(run_payload[:can_resume]).to eq(true)
      end

      it "is false once a newer run on the same Job is queued or running" do
        job = Factories.job_record(repository: repo)
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
        failed_run_with_session(job, workflow)
        job.runs.create!(trigger_kind: "manual", state: "running", started_at: Time.current)

        run_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

        expect(run_payload[:can_resume]).to eq(false)
      end

      it "is false while a WorkUnit-owned workflow is active for the Job" do
        job = Factories.job_record(repository: repo)
        owner = Factories.job_record(repository: repo)
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
        failed_run_with_session(job, workflow)
        owner_workflow = Workflow.create!(job: owner, trigger_kind: "merge_train", state: "running")
        attach_work_unit(owner_workflow, member_jobs: [ owner, job ], kind: "merge_train", state: "running")

        run_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

        expect(run_payload[:can_resume]).to eq(false)
      end

      it "is false without a captured session even when nothing else is active" do
        job = Factories.job_record(repository: repo)
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed")
        step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "failed")
        Run.create!(
          job: job,
          step: step,
          trigger_kind: "initial",
          agent_provider: "claude",
          state: "failed",
          finished_at: 5.minutes.ago
        )

        run_payload = workflows_payload_for(job).dig(:workflows, 0, :steps, 0, :runs, 0)

        expect(run_payload[:can_resume]).to eq(false)
      end
    end
  end

end
