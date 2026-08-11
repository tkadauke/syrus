require "rails_helper"

RSpec.describe StepDispatcher do
  include ActiveJob::TestHelper

  let(:job) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let!(:s1) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s2) { Step.create!(workflow: workflow, kind: "summarize", position: 1) }
  let!(:s3) { Step.create!(workflow: workflow, kind: "pr_open",   position: 2) }

  before do
    s1.update!(next_step_id: s2.id)
    s2.update!(next_step_id: s3.id)
  end

  describe ".start_workflow" do
    it "creates a Run on the first step" do
      expect {
        described_class.start_workflow(workflow)
      }.to change { s1.runs.count }.by(1)
      expect(s1.runs.last.trigger_kind).to eq("initial")
      expect(s1.runs.last.agent_provider).to eq("claude")
    end

    it "copies the workflow agent_provider onto created Runs" do
      workflow.update!(agent_provider: "codex")
      described_class.start_workflow(workflow)
      expect(s1.runs.last.agent_provider).to eq("codex")
    end

    it "is idempotent — won't double-create a Run" do
      described_class.start_workflow(workflow)
      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }
    end

    it "holds ordinary Epic child workflows while an Epic-wide workflow is active" do
      epic = Factories.epic(user: job.user, repository: job.repository)
      keeper_job = Factories.job_record(user: job.user, repository: job.repository, epic: epic, issue_number: 101)
      job.update!(epic: epic)
      keeper = Workflow.create!(job: keeper_job, trigger_kind: "stack_rebase")
      keeper.update_columns(state: "running", started_at: 1.minute.ago)

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }

      expect(workflow.reload).to be_queued
      expect(workflow.artifact("start_blocked_reason")).to eq(StepDispatcher::EPIC_WIDE_BLOCK_REASON)
      expect(workflow.artifact("start_blocked_details")).to include(
        "blocking_workflow_id" => keeper.id,
        "blocking_trigger_kind" => "stack_rebase"
      )
    end

    it "cancels a second Epic-wide workflow before it starts" do
      epic = Factories.epic(user: job.user, repository: job.repository)
      keeper_job = Factories.job_record(user: job.user, repository: job.repository, epic: epic, issue_number: 102)
      job.update!(epic: epic)
      keeper = Workflow.create!(job: keeper_job, trigger_kind: "stack_rebase")
      keeper.update_columns(state: "running", started_at: 1.minute.ago)
      workflow.update!(trigger_kind: "merge_train", artifacts: { "merge_train_id" => 123 })

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }

      expect(workflow.reload).to be_cancelled
      expect(workflow.artifact("start_cancelled_reason")).to eq(StepDispatcher::EPIC_WIDE_BLOCK_REASON)
      expect(workflow.artifact("start_cancelled_details")).to include(
        "blocking_workflow_id" => keeper.id,
        "blocking_trigger_kind" => "stack_rebase"
      )
    end

    it "threads parent_session_id + prompt through to the first Run" do
      described_class.start_workflow(workflow, parent_session_id: "S-prior", prompt: "carry-over")
      run = s1.runs.last
      expect(run.parent_session_id).to eq("S-prior")
      expect(run.prompt).to eq("carry-over")
    end

    it "does not create the first Run while the job is manually paused" do
      job.pause_manually!(by_user: job.user)

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }

      expect(workflow.reload.artifact("pause_reason")).to eq(StepDispatcher::MANUAL_PAUSE_REASON)
      expect(workflow.artifact("pause_kind")).to eq("manual")
      expect(workflow.artifact("start_blocked_reason")).to eq(StepDispatcher::MANUAL_PAUSE_REASON)
      expect(workflow.artifact("start_blocked_next_check_at")).to be_nil
    end

    it "does not create the first Run when provider usage is below the user's provider threshold" do
      workflow.update!(agent_provider: "codex")
      job.user.update!(
        provider_availability_pause_thresholds: { "codex" => 10 },
        codex_usage_status: "warning",
        codex_usage_observed_at: Time.current,
        codex_usage_snapshot: {
          "remaining_percent" => 9.0,
          "primary" => {
            "label" => "weekly",
            "remaining_percent" => 9.0,
            "used_percent" => 91.0,
            "reset_at" => 1.hour.from_now.iso8601
          }
        }
      )

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }

      expect(workflow.reload.artifact("pause_reason")).to eq(StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON)
      expect(workflow.artifact("pause_kind")).to eq("provider_availability")
      expect(workflow.artifact("start_blocked_details")).to include(
        "provider" => "codex",
        "threshold_percent" => 10,
        "remaining_percent" => 9.0
      )
      expect(enqueued_jobs.map { |entry| entry[:job] }).to include(WorkflowPhaseAdmissionJob)
    end

    it "does not provider-pause when the user's provider threshold is zero" do
      workflow.update!(agent_provider: "codex")
      job.user.update!(
        provider_availability_pause_thresholds: { "codex" => 0 },
        codex_usage_status: "exhausted",
        codex_usage_observed_at: Time.current,
        codex_usage_snapshot: { "remaining_percent" => 0.0 }
      )

      expect {
        described_class.start_workflow(workflow)
      }.to change { s1.runs.count }.by(1)
    end

    it "cancels an unstarted workflow when the job closed after workflow creation" do
      job.update_columns(state: "closed", finished_at: Time.current, closure_reason: "operator_cancelled")

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }

      expect(workflow.reload).to be_cancelled
      expect(s1.reload).to be_cancelled
      expect(s2.reload).to be_cancelled
      expect(s3.reload).to be_cancelled
      expect(workflow.artifact("start_cancelled_reason")).to eq("job_closed")
    end

    it "does not create a Run while dependencies are unsatisfied" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }
    end

    it "warns when a non-rebase workflow is left queued by an unresolved stack dependency" do
      JobDependency.create!(
        job: job,
        source: "manual",
        unresolved_owner: job.repository.owner,
        unresolved_repo: job.repository.name,
        unresolved_number: 999
      )

      expect(Rails.logger).to receive(:warn).with(
        include(
          "[StepDispatcher] workflow #{workflow.id} (initial) left queued with 0 runs:",
          "stack_dependencies_not_ready",
          "job_id=#{job.id}"
        )
      )

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { Run.count }
      expect(workflow.reload).to be_queued
    end

    it "starts once dependencies are satisfied" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

      # Closing the prerequisite successfully now starts dependents eagerly
      # (Job#start_dependent_jobs_after_successful_close), rather than
      # waiting for a later explicit re-dispatch.
      expect {
        prerequisite.close_with_reason!("pr_merged")
      }.to change { s1.runs.count }.by(1)

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { s1.runs.count }
    end

    context "when the job is locked by Coding Mode" do
      def enable_coding_mode!(enabled: true)
        feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
          record.category = "Labs"
          record.name = "Coding Mode"
        end
        feature.update!(enabled: enabled)
      end

      it "leaves the workflow queued and does not create a Run when the flag is on" do
        enable_coding_mode!
        chat = ChatSession.create!(user: job.user)
        job.update!(state: "coding", linked_chat_id: chat.id)

        expect {
          described_class.start_workflow(workflow)
        }.not_to change { Run.count }

        expect(workflow.reload).to be_queued
      end

      it "logs an info message when blocked by coding mode lock" do
        enable_coding_mode!
        chat = ChatSession.create!(user: job.user)
        job.update!(state: "coding", linked_chat_id: chat.id)

        expect(Rails.logger).to receive(:info).with(include("held", "in coding state"))
        described_class.start_workflow(workflow)
      end

      it "starts the workflow normally when the feature flag is off even if the job is in coding state" do
        chat = ChatSession.create!(user: job.user)
        job.update!(state: "coding", linked_chat_id: chat.id)

        expect {
          described_class.start_workflow(workflow)
        }.to change { s1.runs.count }.by(1)
      end

      it "starts queued workflows after the lock is released via release_coding_mode_takeover!" do
        enable_coding_mode!
        chat = ChatSession.create!(user: job.user)
        job.update!(state: "coding", linked_chat_id: chat.id)
        described_class.start_workflow(workflow)
        expect(s1.runs.reload.count).to eq(0)

        job.release_coding_mode_takeover!

        expect(s1.runs.reload.count).to eq(1)
      end

      it "starts a new workflow after handoff when linked_chat_id has been cleared" do
        enable_coding_mode!
        chat = ChatSession.create!(user: job.user)
        job.update!(state: "coding", linked_chat_id: chat.id)

        # Simulate complete_coding_handoff!: job is now :implemented and the
        # originating chat id has moved into coding_handoff workflow artifacts.
        job.update!(state: "implemented", linked_chat_id: nil)
        handoff_workflow = Workflow.create!(job: job, trigger_kind: "coding_handoff")
        step = Step.create!(workflow: handoff_workflow, kind: "grader_fanout", position: 0)

        expect {
          described_class.start_workflow(handoff_workflow)
        }.to change { step.runs.count }.by(1)
      end
    end

    it "cancels blocked rebase workflows instead of leaving them active with no Run" do
      prerequisite = Factories.job_record(repository: job.repository, issue_number: 99, state: "closed", closure_reason: "pr_closed")
      blocked_job = Factories.job_record(
        user: job.user,
        repository: job.repository,
        issue_number: 100,
        state: "approved",
        pr_number: 100,
        branch_name: "syrus/issue-100-#{job.id}"
      )
      JobDependency.create!(job: blocked_job, depends_on_job: prerequisite, source: "manual")
      rebase = Workflows::Rebase.instantiate(job: blocked_job)

      expect(RebaseWorkflowSelector.active_for_stack?(blocked_job)).to be(false)

      expect(Rails.logger).not_to receive(:warn).with(include("dependency_failed", "workflow #{rebase.id}"))

      expect {
        described_class.start_workflow(rebase)
      }.not_to change { Run.count }

      expect(rebase.reload).to be_cancelled
      expect(rebase.artifact("start_blocked_reason")).to eq("dependency_failed")
      expect(rebase.steps.pluck(:state).uniq).to eq([ "cancelled" ])
      expect(RebaseWorkflowSelector.active_for_stack?(blocked_job)).to be(false)
    end

    it "starts on an open dependency PR after resolving it as the stack parent" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      prerequisite.update!(branch_name: "syrus/issue-99-#{prerequisite.id}", pr_number: 99)
      prerequisite.runs.create!(trigger_kind: "initial", agent_provider: prerequisite.agent_provider, head_sha: "c" * 40)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

      expect {
        described_class.start_workflow(workflow)
      }.to change { s1.runs.count }.by(1)
      expect(job.reload.parent_job).to eq(prerequisite)
    end

    it "starts landing workflows when redundant transitive dependencies resolve to one stack parent" do
      epic = Factories.epic(user: job.user, repository: job.repository, state: "in_progress")
      root = Factories.job_record(
        user: job.user, repository: job.repository, epic: epic, issue_number: 97, state: "approved",
        branch_name: "syrus/issue-97", pr_number: 97
      )
      root.runs.create!(trigger_kind: "initial", agent_provider: root.agent_provider, head_sha: "a" * 40)
      middle = Factories.job_record(
        user: job.user, repository: job.repository, epic: epic, issue_number: 98, state: "approved",
        branch_name: "syrus/issue-98", pr_number: 98
      )
      middle.runs.create!(trigger_kind: "initial", agent_provider: middle.agent_provider, head_sha: "b" * 40)
      JobDependency.create!(job: middle, depends_on_job: root, source: "manual")
      landing_job = Factories.job_record(
        user: job.user, repository: job.repository, epic: epic, issue_number: 99, state: "approved",
        branch_name: "syrus/issue-99", pr_number: 99
      )
      JobDependency.create!(job: landing_job, depends_on_job: root, source: "manual")
      JobDependency.create!(job: landing_job, depends_on_job: middle, source: "manual")
      auto_merge = Workflows::AutoMerge.instantiate(job: landing_job)
      first_step = auto_merge.first_step

      expect {
        described_class.start_workflow(auto_merge)
      }.to change { first_step.runs.count }.by(1)

      expect(auto_merge.reload).not_to be_failed
      expect(auto_merge.failure_reason).to be_nil
      expect(landing_job.reload.parent_job).to eq(middle)
    end

    it "staggers medium-priority workflows when predicted grader pressure would overlap" do
      repository = job.repository
      existing = Workflows::Initial.instantiate(job: Factories.job_record(user: job.user, repository: repository, priority: "medium"))
      candidate = Workflows::Initial.instantiate(job: Factories.job_record(user: job.user, repository: repository, priority: "medium"))
      candidate_first = candidate.first_step

      %w[prepare implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open].each do |step_kind|
        WorkflowStepResourceProfile.create!(
          repository: repository,
          agent_provider: "claude",
          trigger_kind: "initial",
          step_kind: step_kind,
          grader_name: "",
          job_kind: "issue",
          sample_count: 40,
          p90_duration_seconds: 30,
          p90_cpu_pressure: 2.0,
          p90_io_pressure: 2.0,
          p90_memory_used_percent: 20.0,
          timeout_rate: 0.0,
          failure_rate: 0.0,
          last_observed_at: Time.current,
          profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
        )
      end
      WorkflowStepResourceProfile.create!(
        repository: repository,
        agent_provider: "claude",
        trigger_kind: "initial",
        step_kind: "grader",
        grader_name: "production-build-boot",
        job_kind: "issue",
        sample_count: 40,
        p90_duration_seconds: 2_400,
        p90_cpu_pressure: 70.0,
        p90_io_pressure: 40.0,
        p90_memory_used_percent: 70.0,
        timeout_rate: 0.0,
        failure_rate: 0.0,
        last_observed_at: Time.current,
        profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
      )

      described_class.start_workflow(existing)

      expect {
        described_class.start_workflow(candidate)
      }.not_to change { candidate_first.runs.count }

      expect(candidate.reload).to be_queued
      expect(candidate.artifact("start_blocked_reason")).to eq(StepDispatcher::ADMISSION_BLOCK_REASON)
      expect(candidate.artifact("start_blocked_details")).to include(
        "action" => "delay_until",
        "reason" => "predicted_budget_pressure_high"
      )
      expect(candidate.artifact("start_blocked_details").dig("pressure", "projected", "cpu_pressure")).to be >= 100.0
    end

    it "keeps landing workflows in the landing queue when first-run admission is delayed" do
      landing_job = Factories.job_record(
        user: job.user,
        repository: job.repository,
        state: "landing",
        issue_number: 77,
        pr_number: 77,
        branch_name: "syrus/issue-77",
        approved_at: 1.minute.ago,
        approved_via: "operator"
      )
      auto_merge = Workflows::AutoMerge.instantiate(job: landing_job)
      first_step = auto_merge.first_step
      delay_until = 10.minutes.from_now
      decision = WorkflowAdmissionBudget::Decision.new(
        action: "delay_until",
        reason: "predicted_budget_pressure_high",
        pressure: { "projected" => { "cpu_pressure" => 105.0 } },
        delay_until: delay_until,
        override: false,
        details: { "candidate_seconds" => 1800 }
      )
      allow(WorkflowAdmissionBudget).to receive(:call).and_return(decision)

      expect {
        described_class.start_workflow(auto_merge)
      }.not_to change { first_step.runs.count }

      expect(auto_merge.reload).to be_queued
      expect(auto_merge.failure_reason).to be_nil
      expect(auto_merge.artifact("start_blocked_reason")).to eq("landing start blocked: workflow admission budget")
      expect(auto_merge.artifact("pause_reason")).to be_nil
      expect(auto_merge.artifact("start_blocked_details")).to include(
        "action" => "delay_until",
        "reason" => "predicted_budget_pressure_high"
      )
      expect(auto_merge.artifact("workflow_admission_decision")).to include(
        "action" => "delay_until",
        "reason" => "predicted_budget_pressure_high"
      )
      expect(landing_job.reload).to be_landing
      expect(landing_job.landing_failure_reason).to be_nil
      expect(enqueued_jobs.map { |entry| entry[:job] }).to include(WorkflowPhaseAdmissionJob)
      expect(enqueued_jobs.select { |entry| entry[:job] == WorkflowPhaseAdmissionJob }.last[:at]).to be_within(2.seconds).of(delay_until.to_f)
      expect(enqueued_jobs.map { |entry| entry[:job] }).to include(LandingQueueProcessorJob)
      expect(enqueued_jobs.select { |entry| entry[:job] == LandingQueueProcessorJob }.last[:at]).to be_within(2.seconds).of(delay_until.to_f)
    end

    it "leaves non-landing workflows queued when first-run admission is delayed" do
      delay_until = 10.minutes.from_now
      decision = WorkflowAdmissionBudget::Decision.new(
        action: "delay_until",
        reason: "predicted_budget_pressure_high",
        pressure: { "projected" => { "cpu_pressure" => 105.0 } },
        delay_until: delay_until,
        override: false,
        details: nil
      )
      allow(WorkflowAdmissionBudget).to receive(:call).and_return(decision)

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { s1.runs.count }

      expect(workflow.reload).to be_queued
      expect(workflow.artifact("start_blocked_reason")).to eq(StepDispatcher::ADMISSION_BLOCK_REASON)
      expect(workflow.artifact("start_blocked_details")).to include(
        "action" => "delay_until",
        "reason" => "predicted_budget_pressure_high"
      )
      expect(enqueued_jobs.map { |entry| entry[:job] }).not_to include(LandingQueueProcessorJob)
    end
  end

  describe ".advance_from" do
    it "finishes the current step and then stops before the next step while manually paused" do
      workflow.update!(state: "running", started_at: 1.minute.ago)
      s1.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      job.pause_manually!(by_user: job.user)

      expect {
        described_class.advance_from(s1)
      }.not_to change { s2.runs.count }

      expect(s2.reload).to be_queued
      expect(workflow.reload).to be_running
      expect(workflow.artifact("pause_reason")).to eq(StepDispatcher::MANUAL_PAUSE_REASON)
      expect(workflow.artifact("start_blocked_details")).to include(
        "phase_step_id" => s2.id,
        "phase_step_kind" => "summarize"
      )
    end

    it "finishes the current step and then pauses before the next step when provider usage is exhausted" do
      workflow.update!(state: "running", started_at: 1.minute.ago, agent_provider: "codex")
      s1.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      job.user.update!(
        provider_availability_pause_thresholds: { "codex" => 10 },
        codex_usage_status: "exhausted",
        codex_usage_observed_at: Time.current,
        codex_usage_snapshot: { "remaining_percent" => 0.0 }
      )
      allow(App::ProviderAvailability).to receive(:for_user).and_return(
        {
          provider: "codex",
          label: "Codex",
          state: "exhausted",
          usage_exhausted: true,
          retry_after: 1.hour.from_now.iso8601,
          message: "Codex usage limit has been reached.",
          usage: { remaining_percent: 0.0, observed_at: Time.current.iso8601 }
        }
      )

      expect {
        described_class.advance_from(s1)
      }.not_to change { s2.runs.count }

      expect(workflow.reload.artifact("pause_reason")).to eq(StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON)
      expect(workflow.artifact("start_blocked_details")).to include(
        "reason" => "provider_usage_exhausted",
        "phase_step_id" => s2.id
      )
    end

    it "resumes a manually paused workflow after unpause" do
      workflow.update!(state: "running", started_at: 1.minute.ago)
      s1.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      job.pause_manually!(by_user: job.user)
      described_class.advance_from(s1)

      expect {
        JobManualPause.unpause!(job)
      }.to change { s2.runs.count }.by(1)

      expect(job.reload.manual_paused?).to be(false)
      expect(workflow.reload.artifact("pause_reason")).to be_nil
      expect(workflow.artifact("start_blocked_reason")).to be_nil
    end

    it "creates a Run on the next runnable step" do
      expect {
        described_class.advance_from(s1)
      }.to change { s2.runs.count }.by(1)
      expect(s3.runs.count).to eq(0)  # not yet
    end

    it "skips test_plan without creating a Run when the plan artifact already exists" do
      test_plan = Step.create!(workflow: workflow, kind: "test_plan", position: 2)
      s3.update!(position: 3)
      s2.update!(next_step_id: test_plan.id)
      test_plan.update!(next_step_id: s3.id)
      workflow.set_artifact!("test_plan", { "steps" => [ "Run the tests" ], "notes" => nil })

      expect {
        described_class.advance_from(s2)
      }.to change { s3.runs.count }.by(1)

      expect(test_plan.reload).to be_succeeded
      expect(test_plan.runs.count).to eq(0)
      expect(test_plan.details).to include(
        "skipped" => true,
        "skip_reason" => "test_plan_already_submitted"
      )
    end

    it "skips cancelled steps and creates a Run on the first queued step beyond them" do
      Step.suppress_cancel_cascade do
        s2.update!(state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
      end
      expect {
        described_class.advance_from(s1)
      }.to change { s3.runs.count }.by(1)
      expect(s2.runs.count).to eq(0)
    end

    it "transitions the Workflow to succeeded when no runnable step remains" do
      workflow.start!; workflow.save!
      Step.suppress_cancel_cascade do
        s2.update!(state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
        s3.update!(state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
      end
      described_class.advance_from(s1)
      expect(workflow.reload).to be_succeeded
    end

    it "transitions the Workflow to succeeded after the last step in the chain" do
      workflow.start!; workflow.save!
      described_class.advance_from(s3)  # last step — no next
      expect(workflow.reload).to be_succeeded
    end

    it "does not finish the Workflow while another descendant Step or Run is still active" do
      workflow.start!
      workflow.save!
      s1.update_columns(state: "running", started_at: 1.minute.ago)
      run = s1.runs.create!(job: job, trigger_kind: "initial")
      run.update_columns(state: "running", started_at: 1.minute.ago, last_heartbeat_at: Time.current)
      s3.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
      allow(WorkflowWorkspace).to receive(:cleanup_for)

      described_class.advance_from(s3)

      expect(workflow.reload).to be_running
      expect(WorkflowWorkspace).not_to have_received(:cleanup_for)
    end

    it "schedules a merge-state poll after a pending stacked auto-merge rebase push" do
      clear_enqueued_jobs
      job.repository.update!(auto_merge_enabled: true)
      job.update!(pr_number: 42, branch_name: "syrus/issue-42-#{job.id}")
      pending = Workflows::AutoMerge.instantiate(job: job)
      pending.set_artifact!("pending_auto_merge", "waiting_for_parent")
      pending.cancel!
      pending.save!
      rebase = Workflow.create!(job: job, trigger_kind: "rebase")
      force_push = Step.create!(workflow: rebase, kind: "force_push", position: 0)
      rebase.start!; rebase.save!
      force_push.update!(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)

      described_class.advance_from(force_push)

      expect(enqueued_jobs.any? { |entry| entry[:job] == PollMergeStateJob }).to be(true)
    end

    it "cascades stack child rebases after a force-push workflow succeeds" do
      clear_enqueued_jobs
      job.update!(state: "implemented", pr_number: 42, branch_name: "syrus/issue-42-#{job.id}")
      child = Factories.job(repository: job.repository, issue_number: 43).tap do |child_job|
        JobDependency.create!(job: child_job, depends_on_job: job, source: "manual")
        child_job.update!(
          state: "implemented",
          parent_job: job,
          branch_name: "syrus/issue-43-#{child_job.id}",
          pr_number: 43
        )
        child_job.workflows.update_all(state: "succeeded")
      end
      rebase = Workflow.create!(job: job, trigger_kind: "rebase")
      force_push = Step.create!(workflow: rebase, kind: "force_push", position: 0)
      rebase.start!
      rebase.save!
      force_push.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)

      expect {
        described_class.advance_from(force_push)
      }.to change { child.reload.workflows.where(trigger_kind: "stack_rebase").count }.by(1)

      child_rebase = child.workflows.where(trigger_kind: "stack_rebase").last
      expect(child_rebase.artifact("rebase_base_branch")).to eq(job.branch_name)
      expect(enqueued_jobs.any? { |entry| entry[:job] == RunJob }).to be(true)
    end

    it "cascades stack child rebases after a recovered push workflow succeeds" do
      clear_enqueued_jobs
      job.update!(state: "implemented", pr_number: 42, branch_name: "syrus/issue-42-#{job.id}")
      child = Factories.job(repository: job.repository, issue_number: 43).tap do |child_job|
        JobDependency.create!(job: child_job, depends_on_job: job, source: "manual")
        child_job.update!(
          state: "implemented",
          parent_job: job,
          branch_name: "syrus/issue-43-#{child_job.id}",
          pr_number: 43
        )
        child_job.workflows.update_all(state: "succeeded")
      end
      follow_up = Workflow.create!(job: job, trigger_kind: "pr_comment")
      push_after_rebase = Step.create!(workflow: follow_up, kind: "push_after_rebase", position: 0)
      follow_up.start!
      follow_up.save!
      push_after_rebase.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)

      expect {
        described_class.advance_from(push_after_rebase)
      }.to change { child.reload.workflows.where(trigger_kind: "stack_rebase").count }.by(1)

      child_rebase = child.workflows.where(trigger_kind: "stack_rebase").last
      expect(child_rebase.artifact("rebase_base_branch")).to eq(job.branch_name)
      expect(enqueued_jobs.any? { |entry| entry[:job] == RunJob }).to be(true)
    end

    it "advances a succeeded grade step to the post-loop step" do
      loop_wf = workflow_with_loop(max_iterations: 3)
      grade = loop_wf.steps.find_by!(kind: "grade", iteration: 1)
      summarize = loop_wf.steps.find_by!(kind: "summarize")

      expect {
        described_class.advance_from(grade)
      }.to change { summarize.runs.count }.by(1)
    end

    it "keeps workflows without loops on the existing linear path" do
      expect {
        described_class.advance_from(s1)
      }.to change { s2.runs.count }.by(1)

      expect(workflow.steps.where.not(loop_id: nil)).to be_empty
      expect(workflow.reload).to be_queued
    end
  end

  describe ".fail_from" do
    it "materializes the next loop iteration when grade fails with budget remaining" do
      loop_wf = workflow_with_loop(max_iterations: 3)
      implement = loop_wf.steps.find_by!(kind: "implement", iteration: 1)
      grade = loop_wf.steps.find_by!(kind: "grade", iteration: 1)
      summarize = loop_wf.steps.find_by!(kind: "summarize")
      run = implement.runs.create!(job: job, trigger_kind: "manual")
      ProviderSession.create!(run: run, session_id: "S-iter-1", transcript_jsonl: "{}\n")

      expect {
        described_class.fail_from(grade)
      }.to change { loop_wf.steps.count }.by(2)
       .and change { Run.count }.by(1)

      new_steps = loop_wf.reload.steps.where(loop_id: grade.loop_id, iteration: 2).order(:position).to_a
      expect(new_steps.map(&:kind)).to eq(%w[ implement grade ])
      expect(grade.reload.next_step).to eq(new_steps.first)
      expect(new_steps.first.next_step).to eq(new_steps.last)
      expect(new_steps.last.next_step).to eq(summarize)
      expect(new_steps.first.runs.last.parent_session_id).to eq("S-iter-1")
      expect(new_steps.first.runs.last.iteration).to eq(2)
    end

    it "spends the loop budget before failing the workflow after repeated grade failures" do
      loop_wf = workflow_with_loop(max_iterations: 3)
      loop_wf.start!; loop_wf.save!

      described_class.fail_from(loop_wf.steps.find_by!(kind: "grade", iteration: 1))
      expect(loop_wf.reload).to be_running
      expect(loop_wf.failure_count).to eq(0)
      expect(loop_wf.steps.where(kind: "implement").pluck(:iteration)).to eq([ 1, 2 ])

      described_class.fail_from(loop_wf.steps.find_by!(kind: "grade", iteration: 2))
      expect(loop_wf.reload).to be_running
      expect(loop_wf.failure_count).to eq(0)
      expect(loop_wf.steps.where(kind: "implement").pluck(:iteration)).to eq([ 1, 2, 3 ])

      described_class.fail_from(loop_wf.steps.find_by!(kind: "grade", iteration: 3))
      expect(loop_wf.reload).to be_failed
      expect(loop_wf.failure_reason).to eq("loop_exhausted_after_grader_failure")
      expect(loop_wf.failure_count).to eq(1)
    end

    it "fails the workflow and cancels post-loop steps when grade exhausts the loop budget" do
      loop_wf = workflow_with_loop(max_iterations: 1)
      loop_wf.start!; loop_wf.save!
      grade = loop_wf.steps.find_by!(kind: "grade", iteration: 1)
      summarize = loop_wf.steps.find_by!(kind: "summarize")
      pr_open = loop_wf.steps.find_by!(kind: "pr_open")

      described_class.fail_from(grade)

      expect(loop_wf.reload).to be_failed
      expect(loop_wf.failure_reason).to eq("loop_exhausted_after_grader_failure")
      expect(loop_wf.failure_count).to eq(1)
      expect(summarize.reload).to be_cancelled
      expect(summarize.cancellation_reason).to eq("loop_exhausted_after_grader_failure")
      expect(pr_open.reload).to be_cancelled
      expect(pr_open.cancellation_reason).to eq("loop_exhausted_after_grader_failure")
    end

    it "hard-fails the workflow when a non-grade step inside a loop fails" do
      loop_wf = workflow_with_loop(max_iterations: 3)
      loop_wf.start!; loop_wf.save!
      implement = loop_wf.steps.find_by!(kind: "implement", iteration: 1)

      expect {
        described_class.fail_from(implement)
      }.not_to change { loop_wf.steps.count }

      expect(loop_wf.reload).to be_failed
      expect(loop_wf.failure_reason).to be_nil
    end
  end

  describe ".fail_from" do
    it "inserts the next loop iteration before continuation steps" do
      workflow_class = Class.new(Workflows::Base) do
        steps Workflows::Loop.new(max_iterations: 2, steps: [ :implement, :grade ]),
              :summarize,
              :pr_open

        def self.trigger_kind = "initial"
      end
      loop_workflow = workflow_class.instantiate(job: job)
      implement, grade, summarize, pr_open = loop_workflow.steps.order(:position)

      expect {
        described_class.fail_from(grade)
      }.to change { Run.count }.by(1)

      loop_id = implement.loop_id
      expect(loop_workflow.steps.order(:position).pluck(:kind, :position, :iteration, :loop_id)).to eq([
        [ "implement", 0, 1, loop_id ],
        [ "grade", 1, 1, loop_id ],
        [ "implement", 2, 2, loop_id ],
        [ "grade", 3, 2, loop_id ],
        [ "summarize", 4, 1, nil ],
        [ "pr_open", 5, 1, nil ]
      ])
      expect(grade.reload.next_step).to eq(loop_workflow.steps.find_by!(kind: "implement", iteration: 2))
      expect(loop_workflow.steps.find_by!(kind: "grade", iteration: 2).next_step).to eq(summarize)
      expect(pr_open.reload.position).to eq(5)
    end

    it "inserts retry_until repair steps only after a failed check-only first iteration" do
      workflow_class = Class.new(Workflows::Base) do
        steps Workflows::RetryUntil.new(
                max_iterations: 2,
                repair_first: false,
                repair: [ :landing_fix ],
                check: [ :grader_fanout, :grader_collect ]
              ),
              :push,
              :auto_merge

        def self.trigger_kind = "auto_merge"
      end
      retry_workflow = workflow_class.instantiate(job: job)
      grader_fanout, grader_collect, push, auto_merge = retry_workflow.steps.order(:position)

      expect {
        described_class.fail_from(grader_collect)
      }.to change { Run.count }.by(1)

      loop_id = grader_fanout.loop_id
      expect(retry_workflow.steps.order(:position).pluck(:kind, :position, :iteration, :loop_id)).to eq([
        [ "grader_fanout", 0, 1, loop_id ],
        [ "grader_collect", 1, 1, loop_id ],
        [ "landing_fix", 2, 2, loop_id ],
        [ "grader_fanout", 3, 2, loop_id ],
        [ "grader_collect", 4, 2, loop_id ],
        [ "push", 5, 1, nil ],
        [ "auto_merge", 6, 1, nil ]
      ])
      expect(grader_collect.reload.next_step).to eq(retry_workflow.steps.find_by!(kind: "landing_fix", iteration: 2))
      expect(retry_workflow.steps.find_by!(kind: "grader_collect", iteration: 2).next_step).to eq(push)
      expect(auto_merge.reload.position).to eq(6)
    end

    it "advances retry_until check-only first iteration without materializing repair when checks pass" do
      workflow_class = Class.new(Workflows::Base) do
        steps Workflows::RetryUntil.new(
                max_iterations: 2,
                repair_first: false,
                repair: [ :landing_fix ],
                check: [ :grader_fanout, :grader_collect ]
              ),
              :push

        def self.trigger_kind = "auto_merge"
      end
      retry_workflow = workflow_class.instantiate(job: job)
      grader_collect = retry_workflow.steps.find_by!(kind: "grader_collect")
      push = retry_workflow.steps.find_by!(kind: "push")
      original_step_count = retry_workflow.steps.count

      expect {
        described_class.advance_from(grader_collect)
      }.to change { push.runs.count }.by(1)

      expect(retry_workflow.steps.count).to eq(original_step_count)
      expect(push.runs.last.iteration).to eq(1)
      expect(retry_workflow.steps.find_by(kind: "landing_fix")).to be_nil
    end

    it "expands the merge_train_land failure branch when base moved" do
      try_workflow = workflow_with_try_merge_train_land_branch
      land = try_workflow.steps.find_by!(kind: "merge_train_land")
      land.update!(details: land.details.merge("failure_code" => Steps::MergeTrainLand::BaseMoved::FAILURE_CODE))

      expect {
        described_class.fail_from(land)
      }.to change { try_workflow.steps.count }.by(4)
        .and change { Run.count }.by(1)

      branch_steps = try_workflow.reload.steps.order(:position).to_a
      loop_id = try_workflow.steps.find_by!(kind: "grader_collect").loop_id

      expect(branch_steps.map { |s| [ s.kind, s.position, s.iteration, s.loop_id ] }).to eq([
        [ "merge_train_build",            0, 1, nil ],
        [ "merge_train_land",             1, 1, nil ],
        [ "merge_train_rebase",           2, 1, nil ],
        [ "grader_fanout",                3, 1, loop_id ],
        [ "grader_collect",               4, 1, loop_id ],
        [ "merge_train_land_after_rebase", 5, 1, nil ]
      ])
      expect(land.reload.next_step).to eq(try_workflow.steps.find_by!(kind: "merge_train_rebase"))
      expect(try_workflow.steps.find_by!(kind: "merge_train_land_after_rebase").next_step).to be_nil
      expect(try_workflow.steps.find_by!(kind: "merge_train_rebase").runs.last.trigger_kind).to eq("merge_train")
      expect(land.details).to include(
        "try_branch_expanded" => true,
        "try_branch_failure_code" => Steps::MergeTrainLand::BaseMoved::FAILURE_CODE
      )
    end

    it "expands a Try failure branch before the continuation step" do
      try_workflow = workflow_with_try_push_branch
      push = try_workflow.steps.find_by!(kind: "push")
      continuation = try_workflow.steps.find_by!(kind: "auto_merge")
      push.update!(details: push.details.merge("failure_code" => "remote_branch_advanced_rebase_conflict"))

      expect {
        described_class.fail_from(push)
      }.to change { try_workflow.steps.count }.by(4)
        .and change { Run.count }.by(1)

      branch_steps = try_workflow.reload.steps.order(:position).to_a
      loop_id = try_workflow.steps.find_by!(kind: "grader_collect").loop_id

      expect(branch_steps.map { |step| [ step.kind, step.position, step.iteration, step.loop_id ] }).to eq([
        [ "summarize_amend", 0, 1, nil ],
        [ "push", 1, 1, nil ],
        [ "push_agent_rebase", 2, 1, nil ],
        [ "grader_fanout", 3, 1, loop_id ],
        [ "grader_collect", 4, 1, loop_id ],
        [ "push_after_rebase", 5, 1, nil ],
        [ "auto_merge", 6, 1, nil ]
      ])
      expect(push.reload.next_step).to eq(try_workflow.steps.find_by!(kind: "push_agent_rebase"))
      expect(try_workflow.steps.find_by!(kind: "push_after_rebase").next_step).to eq(continuation)
      expect(try_workflow.steps.find_by!(kind: "push_agent_rebase").runs.last.trigger_kind).to eq("pr_comment")
      expect(push.details).to include(
        "try_branch_expanded" => true,
        "try_branch_failure_code" => "remote_branch_advanced_rebase_conflict"
      )

      expect {
        described_class.fail_from(push.reload)
      }.not_to change { try_workflow.steps.count }
    end

    it "runs retry_until repair iterations inside an expanded Try branch" do
      try_workflow = workflow_with_try_push_branch
      push = try_workflow.steps.find_by!(kind: "push")
      push.update!(details: push.details.merge("failure_code" => "remote_branch_advanced_rebase_conflict"))
      described_class.fail_from(push)

      grader_collect = try_workflow.reload.steps.find_by!(kind: "grader_collect", iteration: 1)
      push_after_rebase = try_workflow.steps.find_by!(kind: "push_after_rebase")

      expect {
        described_class.fail_from(grader_collect)
      }.to change { try_workflow.steps.count }.by(3)
        .and change { Run.count }.by(1)

      loop_id = grader_collect.loop_id
      expect(try_workflow.reload.steps.order(:position).pluck(:kind, :position, :iteration, :loop_id)).to eq([
        [ "summarize_amend", 0, 1, nil ],
        [ "push", 1, 1, nil ],
        [ "push_agent_rebase", 2, 1, nil ],
        [ "grader_fanout", 3, 1, loop_id ],
        [ "grader_collect", 4, 1, loop_id ],
        [ "landing_fix", 5, 2, loop_id ],
        [ "grader_fanout", 6, 2, loop_id ],
        [ "grader_collect", 7, 2, loop_id ],
        [ "push_after_rebase", 8, 1, nil ],
        [ "auto_merge", 9, 1, nil ]
      ])
      expect(grader_collect.reload.next_step).to eq(try_workflow.steps.find_by!(kind: "landing_fix", iteration: 2))
      expect(try_workflow.steps.find_by!(kind: "grader_collect", iteration: 2).next_step).to eq(push_after_rebase)
      expect(try_workflow.steps.find_by!(kind: "landing_fix", iteration: 2).runs.last).to be_present
    end

    it "exits an exhausted adversarial review loop to the final implement step" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 1)
      implement = review_workflow.steps.find_by!(kind: "implement", iteration: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review.loop_id).sole
      ProviderSession.create!(
        run: implement.runs.create!(job: job, trigger_kind: "initial"),
        session_id: "implement-1",
        transcript_jsonl: "{}\n"
      )

      original_step_count = review_workflow.steps.count

      expect {
        described_class.advance_from(review)
      }.to change { final_implement.runs.count }.by(1)

      expect(review_workflow.steps.count).to eq(original_step_count)
      expect(final_implement.runs.last.parent_session_id).to be_nil
    end

    it "materializes the next adversarial review iteration before the final implement step" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 2)
      implement = review_workflow.steps.find_by!(kind: "implement", iteration: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review.loop_id).sole
      ProviderSession.create!(
        run: implement.runs.create!(job: job, trigger_kind: "initial"),
        session_id: "implement-1",
        transcript_jsonl: "{}\n"
      )

      expect {
        described_class.advance_from(review)
      }.to change { review_workflow.steps.count }.by(2)
        .and change { Run.count }.by(1)

      new_steps = review_workflow.reload.steps.where(loop_id: review.loop_id, iteration: 2).order(:position).to_a
      expect(new_steps.map(&:kind)).to eq(%w[ implement adversarial_review ])
      expect(review.reload.next_step).to eq(new_steps.first)
      expect(new_steps.last.next_step).to eq(final_implement)
      expect(new_steps.first.runs.last.parent_session_id).to eq("implement-1")
    end

    it "uses the implement session, not the reviewer session, for adversarial loop repair continuity" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 2)
      implement = review_workflow.steps.find_by!(kind: "implement", iteration: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      implement_run = implement.runs.create!(job: job, trigger_kind: "initial")
      review_run = review.runs.create!(job: job, trigger_kind: "initial")
      ProviderSession.create!(run: implement_run, session_id: "implementer-session", transcript_jsonl: "{}\n")
      ProviderSession.create!(run: review_run, session_id: "reviewer-session", transcript_jsonl: "{}\n")

      dispatcher = described_class.new(review_workflow, advancing_from: review)

      expect(dispatcher.send(:prior_iteration_session_id)).to eq("implementer-session")
    end

    it "skips final implement and enqueues grader_fanout when reviewer approves mid-loop (iteration 1 of 2)" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 2)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review.loop_id).sole
      grader_fanout = review_workflow.steps.find_by!(kind: "grader_fanout")

      review_workflow.set_artifact!("adversarial_review_iterations", [
        { "iteration" => 1, "critique" => "LGTM", "verdict" => "approved" }
      ])

      original_step_count = review_workflow.steps.count

      expect {
        described_class.advance_from(review)
      }.to change { grader_fanout.runs.count }.by(1)

      expect(review_workflow.reload.steps.count).to eq(original_step_count)
      expect(final_implement.reload).to be_cancelled
      expect(final_implement.cancellation_reason).to eq("adversarial_review_approved")
      expect(grader_fanout.reload).to be_queued
      expect(review_workflow.steps.find_by!(kind: "grader_collect")).to be_queued
      expect(review_workflow.reload).not_to be_cancelled
      expect(review_workflow.steps.where(loop_id: review.loop_id, iteration: 2)).to be_empty
    end

    it "skips final implement and enqueues grader_fanout when reviewer approves at last iteration (iteration 2 of 2)" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 2)
      review1 = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review1.loop_id).sole
      grader_fanout = review_workflow.steps.find_by!(kind: "grader_fanout")

      # Materialize the second loop iteration (as enqueue_next_loop_iteration! would)
      implement2 = Step.create!(workflow: review_workflow, kind: "implement", position: 3,
                                iteration: 2, loop_id: review1.loop_id)
      review2 = Step.create!(workflow: review_workflow, kind: "adversarial_review", position: 4,
                              iteration: 2, loop_id: review1.loop_id)
      review_workflow.steps.where("position >= 3").where.not(id: [ implement2.id, review2.id ])
                     .update_all("position = position + 2")
      review1.update!(next_step_id: implement2.id)
      implement2.update!(next_step_id: review2.id)
      review2.update!(next_step_id: final_implement.id)

      review_workflow.set_artifact!("adversarial_review_iterations", [
        { "iteration" => 1, "critique" => "needs work", "verdict" => "needs_work" },
        { "iteration" => 2, "critique" => "LGTM", "verdict" => "approved" }
      ])

      original_step_count = review_workflow.reload.steps.count

      expect {
        described_class.advance_from(review2)
      }.to change { grader_fanout.runs.count }.by(1)

      expect(review_workflow.reload.steps.count).to eq(original_step_count)
      expect(final_implement.reload).to be_cancelled
      expect(final_implement.cancellation_reason).to eq("adversarial_review_approved")
      expect(grader_fanout.reload).to be_queued
      expect(review_workflow.steps.find_by!(kind: "grader_collect")).to be_queued
      expect(review_workflow.reload).not_to be_cancelled
    end

    it "does not skip final implement when verdict is needs_work with iterations remaining" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 2)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review.loop_id).sole

      review_workflow.set_artifact!("adversarial_review_iterations", [
        { "iteration" => 1, "critique" => "needs more work", "verdict" => "needs_work" }
      ])

      expect {
        described_class.advance_from(review)
      }.to change { review_workflow.steps.count }.by(2)

      expect(final_implement.runs.reload).to be_empty
      expect(final_implement.reload).to be_queued
    end

    it "falls through to final implement when verdict is needs_work and iterations exhausted" do
      review_workflow = workflow_with_adversarial_review_loop(max_iterations: 1)
      review = review_workflow.steps.find_by!(kind: "adversarial_review", iteration: 1)
      final_implement = review_workflow.steps.where(kind: "implement").where.not(loop_id: review.loop_id).sole

      review_workflow.set_artifact!("adversarial_review_iterations", [
        { "iteration" => 1, "critique" => "still needs work", "verdict" => "needs_work" }
      ])

      expect {
        described_class.advance_from(review)
      }.to change { final_implement.runs.count }.by(1)

      expect(final_implement.reload).to be_queued
    end
  end

  describe "Step#after_update_commit advance integration" do
    it "fires StepDispatcher.advance_from when a step transitions to succeeded" do
      run = s1.runs.create!(job: job, trigger_kind: "initial")
      run.start!; run.save!
      s1.start!; s1.save!
      expect(described_class).to receive(:advance_from).with(s1)
      s1.succeed!; s1.save!
    end
  end

  describe "Step#after_update_commit fail integration" do
    it "fires StepDispatcher.fail_from when a step transitions to failed" do
      s1.start!; s1.save!
      expect(described_class).to receive(:fail_from).with(s1)
      s1.fail!; s1.save!
    end

    it "routes failed loop grade steps through the dispatcher without failing early" do
      loop_wf = workflow_with_loop(max_iterations: 3)
      loop_wf.start!; loop_wf.save!
      grade = loop_wf.steps.find_by!(kind: "grade", iteration: 1)

      grade.start!; grade.save!
      grade.fail!; grade.save!

      expect(loop_wf.reload).to be_running
      expect(loop_wf.failure_count).to eq(0)
      expect(loop_wf.steps.find_by(kind: "implement", iteration: 2)).to be_present
    end
  end

  def workflow_with_loop(max_iterations:)
    Workflow.create!(
      job: job,
      trigger_kind: "manual",
      chain_template: [
        { "type" => "step", "kind" => "prepare" },
        { "type" => "loop", "max_iterations" => max_iterations, "steps" => %w[ implement grade ] },
        { "type" => "step", "kind" => "summarize" },
        { "type" => "step", "kind" => "pr_open" }
      ]
    ).tap do |wf|
      prepare = Step.create!(workflow: wf, kind: "prepare", position: 0)
      implement = Step.create!(workflow: wf, kind: "implement", position: 1, iteration: 1, loop_id: "loop-a")
      grade = Step.create!(workflow: wf, kind: "grade", position: 2, iteration: 1, loop_id: "loop-a")
      summarize = Step.create!(workflow: wf, kind: "summarize", position: 3)
      pr_open = Step.create!(workflow: wf, kind: "pr_open", position: 4)
      prepare.update!(next_step_id: implement.id)
      implement.update!(next_step_id: grade.id)
      grade.update!(next_step_id: summarize.id)
      summarize.update!(next_step_id: pr_open.id)
    end
  end

  def workflow_with_adversarial_review_loop(max_iterations:)
    Workflow.create!(
      job: job,
      trigger_kind: "initial",
      chain_template: [
        { "type" => "step", "kind" => "prepare" },
        { "type" => "loop", "max_iterations" => max_iterations, "steps" => %w[ implement adversarial_review ] },
        {
          "type" => "retry_until",
          "max_iterations" => 1,
          "repair" => %w[ implement ],
          "check" => %w[ grader_fanout grader_collect ],
          "repair_first" => true
        }
      ]
    ).tap do |wf|
      prepare = Step.create!(workflow: wf, kind: "prepare", position: 0)
      implement = Step.create!(workflow: wf, kind: "implement", position: 1, iteration: 1, loop_id: "review-loop")
      review = Step.create!(workflow: wf, kind: "adversarial_review", position: 2, iteration: 1, loop_id: "review-loop")
      final_implement = Step.create!(workflow: wf, kind: "implement", position: 3, iteration: 1, loop_id: "grade-loop")
      grader_fanout = Step.create!(workflow: wf, kind: "grader_fanout", position: 4, iteration: 1, loop_id: "grade-loop")
      grader_collect = Step.create!(workflow: wf, kind: "grader_collect", position: 5, iteration: 1, loop_id: "grade-loop")
      prepare.update!(next_step_id: implement.id)
      implement.update!(next_step_id: review.id)
      review.update!(next_step_id: final_implement.id)
      final_implement.update!(next_step_id: grader_fanout.id)
      grader_fanout.update!(next_step_id: grader_collect.id)
    end
  end

  def workflow_with_try_merge_train_land_branch
    try_id = "try-merge-train-land"
    Workflow.create!(
      job: job,
      trigger_kind: "merge_train",
      chain_template: [
        { "type" => "step", "kind" => "merge_train_build" },
        {
          "type" => "try",
          "id" => try_id,
          "step" => "merge_train_land",
          "on_failure" => {
            Steps::MergeTrainLand::BaseMoved::FAILURE_CODE => [
              { "type" => "step", "kind" => "merge_train_rebase" },
              {
                "type" => "retry_until",
                "max_iterations" => 2,
                "repair" => %w[ landing_fix ],
                "check" => %w[ grader_fanout grader_collect ],
                "repair_first" => false
              },
              { "type" => "step", "kind" => "merge_train_land_after_rebase" }
            ]
          }
        }
      ]
    ).tap do |wf|
      build = Step.create!(workflow: wf, kind: "merge_train_build", position: 0)
      land  = Step.create!(workflow: wf, kind: "merge_train_land", position: 1, details: { "try_id" => try_id })
      build.update!(next_step_id: land.id)
    end
  end

  def workflow_with_try_push_branch
    try_id = "try-push"
    Workflow.create!(
      job: job,
      trigger_kind: "pr_comment",
      chain_template: [
        { "type" => "step", "kind" => "summarize_amend" },
        {
          "type" => "try",
          "id" => try_id,
          "step" => "push",
          "on_failure" => {
            "remote_branch_advanced_rebase_conflict" => [
              { "type" => "step", "kind" => "push_agent_rebase" },
              {
                "type" => "retry_until",
                "max_iterations" => 2,
                "repair" => %w[ landing_fix ],
                "check" => %w[ grader_fanout grader_collect ],
                "repair_first" => false
              },
              { "type" => "step", "kind" => "push_after_rebase" }
            ]
          }
        },
        { "type" => "step", "kind" => "auto_merge" }
      ]
    ).tap do |wf|
      summarize = Step.create!(workflow: wf, kind: "summarize_amend", position: 0)
      push = Step.create!(workflow: wf, kind: "push", position: 1, details: { "try_id" => try_id })
      auto_merge = Step.create!(workflow: wf, kind: "auto_merge", position: 2)
      summarize.update!(next_step_id: push.id)
      push.update!(next_step_id: auto_merge.id)
    end
  end
end

RSpec.describe StepDispatcher, "phase admission gate" do
  include ActiveJob::TestHelper

  let(:job_model) { Factories.job_record(state: "queued") }
  let!(:workflow) { Workflow.create!(job: job_model, trigger_kind: "initial") }
  let!(:implement) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:grader_fanout) { Step.create!(workflow: workflow, kind: "grader_fanout", position: 1) }

  before do
    AppSetting.current.update!(workflow_admission_policy: "phase_aware")
    clear_enqueued_jobs
    implement.update!(next_step_id: grader_fanout.id)
    workflow.update!(state: "running", started_at: 1.minute.ago)
    implement.update_columns(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
  end

  def resource_profile(step_kind:, duration: 2_400, cpu: 90.0, io: 40.0, memory: 70.0, grader_name: "")
    WorkflowStepResourceProfile.create!(
      repository: job_model.repository,
      agent_provider: workflow.agent_provider,
      trigger_kind: workflow.trigger_kind,
      step_kind: step_kind,
      grader_name: grader_name,
      job_kind: job_model.kind.to_s,
      sample_count: 40,
      p90_duration_seconds: duration,
      p90_cpu_pressure: cpu,
      p90_io_pressure: io,
      p90_memory_used_percent: memory,
      timeout_rate: 0.0,
      failure_rate: 0.0,
      last_observed_at: Time.current,
      profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
    )
  end

  def worker_pressure!(cpu: 90.0, memory: 50.0)
    WorkerHostHealthSample.create!(
      hostname: "worker-1",
      role: "worker",
      version: "test",
      observed_at: Time.current,
      cpu_pressure_some: cpu,
      memory_used_percent: memory,
      raw_metrics: {}
    )
  end

  it "defers a costly grader phase while worker pressure is high" do
    worker_pressure!
    resource_profile(step_kind: "grader", grader_name: "production-build-boot")

    expect {
      described_class.advance_from(implement)
    }.not_to change { grader_fanout.runs.count }

    expect(workflow.reload.artifact("start_blocked_reason")).to eq(StepDispatcher::ADMISSION_BLOCK_REASON)
    expect(workflow.artifact("pause_reason")).to eq(StepDispatcher::PAUSE_REASON_ADMISSION)
    expect(workflow.artifact("start_blocked_details")).to include(
      "action" => "delay_until",
      "reason" => "worker_host_pressure_high",
      "phase_step_id" => grader_fanout.id,
      "phase_step_kind" => "grader_fanout"
    )
    recheck_jobs = enqueued_jobs.select { |entry| entry[:job] == WorkflowPhaseAdmissionJob }
    expect(recheck_jobs).to be_present
    expect(recheck_jobs.last[:priority]).to eq(job_model.solid_queue_priority)
  end

  it "fails and defers landing workflows instead of holding the landing lane at a phase boundary" do
    landing_job = Factories.job_record(
      user: job_model.user,
      repository: job_model.repository,
      state: "landing",
      issue_number: 77,
      pr_number: 77,
      branch_name: "syrus/issue-77",
      approved_at: 1.minute.ago,
      approved_via: "operator"
    )
    landing_workflow = Workflow.create!(
      job: landing_job,
      trigger_kind: "auto_merge",
      state: "running",
      started_at: 1.minute.ago
    )
    preflight = Step.create!(
      workflow: landing_workflow,
      kind: "mergeability_preflight",
      position: 0,
      state: "succeeded",
      started_at: 1.minute.ago,
      finished_at: Time.current
    )
    prepare = Step.create!(workflow: landing_workflow, kind: "prepare", position: 1)
    preflight.update!(next_step_id: prepare.id)
    preflight.runs.create!(
      job: landing_job,
      trigger_kind: landing_workflow.trigger_kind,
      agent_provider: landing_workflow.agent_provider,
      state: "succeeded",
      started_at: 1.minute.ago,
      finished_at: Time.current
    )
    delay_until = 10.minutes.from_now
    decision = WorkflowAdmissionBudget::Decision.new(
      action: "delay_until",
      reason: "minimum_progress_floor",
      pressure: { "projected" => { "cpu_pressure" => 105.0 } },
      delay_until: delay_until,
      override: false,
      details: { "candidate_seconds" => 1800 }
    )
    allow(WorkflowAdmissionBudget).to receive(:call).with(workflow: landing_workflow, step: prepare).and_return(decision)

    expect {
      described_class.advance_from(preflight)
    }.not_to change { prepare.runs.count }

    expect(landing_workflow.reload).to be_running
    expect(landing_workflow.failure_reason).to be_nil
    expect(landing_workflow.artifact("start_blocked_reason")).to eq("landing start blocked: workflow admission budget")
    expect(landing_workflow.artifact("pause_reason")).to be_nil
    expect(landing_workflow.artifact("start_blocked_details")).to include(
      "action" => "delay_until",
      "reason" => "minimum_progress_floor",
      "phase_step_id" => prepare.id,
      "phase_step_kind" => "prepare"
    )
    expect(landing_workflow.artifact("workflow_admission_decision")).to include(
      "action" => "delay_until",
      "reason" => "minimum_progress_floor",
      "phase_step_id" => prepare.id
    )
    expect(landing_job.reload).to be_landing
    expect(landing_job.landing_failure_reason).to be_nil
    expect(enqueued_jobs.map { |entry| entry[:job] }).to include(WorkflowPhaseAdmissionJob)
    expect(enqueued_jobs.select { |entry| entry[:job] == WorkflowPhaseAdmissionJob }.last[:at]).to be_within(2.seconds).of(delay_until.to_f)
    expect(enqueued_jobs.select { |entry| entry[:job] == LandingQueueProcessorJob }.last[:at]).to be_within(2.seconds).of(delay_until.to_f)
  end

  it "admits a deferred grader phase when pressure falls" do
    worker_pressure!
    resource_profile(step_kind: "grader", grader_name: "production-build-boot")
    described_class.advance_from(implement)
    WorkerHostHealthSample.delete_all

    expect {
      described_class.resume_deferred_phase(workflow.id, grader_fanout.id)
    }.to change { grader_fanout.runs.count }.by(1)

    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
  end

  it "does not defer a normal phase for soft pressure under whole-workflow policy" do
    AppSetting.current.update!(workflow_admission_policy: "whole_workflow")
    worker_pressure!
    resource_profile(step_kind: "grader", grader_name: "production-build-boot")

    expect {
      described_class.advance_from(implement)
    }.to change { grader_fanout.runs.count }.by(1)

    expect(workflow.reload.artifact("pause_reason")).to be_nil
    expect(workflow.artifact("start_blocked_reason")).to be_nil
  end

  it "pauses a phase for hard resource pressure under whole-workflow policy" do
    AppSetting.current.update!(workflow_admission_policy: "whole_workflow")
    worker_pressure!(memory: 97.0)

    expect {
      described_class.advance_from(implement)
    }.not_to change { grader_fanout.runs.count }

    expect(workflow.reload.artifact("pause_reason")).to eq(StepDispatcher::PAUSE_REASON_RESOURCE_SAFETY)
    expect(workflow.artifact("pause_kind")).to eq("hard_resource_pressure")
    expect(workflow.artifact("start_blocked_reason")).to eq(StepDispatcher::PAUSE_REASON_RESOURCE_SAFETY)
    expect(enqueued_jobs.map { |entry| entry[:job] }).to include(WorkflowPhaseAdmissionJob)
  end

  it "preserves urgent priority semantics at phase boundaries" do
    job_model.update_columns(priority: "urgent")
    worker_pressure!
    resource_profile(step_kind: "grader", grader_name: "production-build-boot")

    expect {
      described_class.advance_from(implement)
    }.to change { grader_fanout.runs.count }.by(1)

    expect(workflow.reload.artifact("workflow_admission_override")).to include(
      "reason" => "urgent_priority_override",
      "override" => true
    )
  end

  it "does not deadlock a phase when no resource profile exists" do
    worker_pressure!

    expect {
      described_class.advance_from(implement)
    }.to change { grader_fanout.runs.count }.by(1)

    expect(workflow.reload.artifact("workflow_admission_decision")).to include(
      "action" => "admit_low_risk_only",
      "reason" => "worker_host_pressure_high"
    )
  end
end

RSpec.describe StepDispatcher, "urgent_blocking gate" do
  include ActiveJob::TestHelper

  let(:job_model) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job_model, trigger_kind: "initial") }
  let!(:s1) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s2) { Step.create!(workflow: workflow, kind: "pr_open", position: 1) }

  before { s1.update!(next_step_id: s2.id) }

  def create_urgent_job!(state: "queued")
    Factories.job_record(
      user: job_model.user,
      repository: job_model.repository,
      priority: "urgent",
      state: state
    )
  end

  it "does not block when no urgent jobs exist in the repository" do
    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "blocks non-urgent workflows when an open urgent job exists" do
    create_urgent_job!
    expect {
      described_class.start_workflow(workflow)
    }.not_to change { Run.count }
    expect(workflow.reload).to be_queued
  end

  it "records urgent_job_active as the block reason" do
    create_urgent_job!
    described_class.start_workflow(workflow)
    expect(workflow.reload.artifact("start_blocked_reason")).to eq("urgent_job_active")
  end

  it "logs a warning when blocked by urgent job" do
    create_urgent_job!
    expect(Rails.logger).to receive(:warn).with(include("urgent_job_active"))
    described_class.start_workflow(workflow)
  end

  it "backs off repeated urgent-blocked starts" do
    create_urgent_job!
    travel_to(Time.zone.parse("2026-07-15 12:00:00 UTC")) do
      expect(Rails.logger).to receive(:warn).once.with(include("urgent_job_active"))

      described_class.start_workflow(workflow)
      next_check_at = workflow.reload.artifact("start_blocked_next_check_at")

      described_class.start_workflow(workflow)

      expect(workflow.reload.artifact("start_blocked_reason")).to eq("urgent_job_active")
      expect(workflow.artifact("start_blocked_next_check_at")).to eq(next_check_at)
    end
  end

  it "does not block urgent workflows even when other urgent jobs exist" do
    create_urgent_job!
    job_model.update_columns(priority: "urgent")

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "does not block main_grader workflows when an urgent job exists" do
    create_urgent_job!
    main_grader_job = Job.create!(
      user: job_model.user,
      repository: job_model.repository,
      kind: "main_grader",
      issue_title: "main_grader:abc123",
      issue_number: nil
    )
    main_grader_workflow = Workflow.create!(
      job: main_grader_job,
      trigger_kind: "main_grader"
    )
    grader_fanout = Step.create!(workflow: main_grader_workflow, kind: "grader_fanout", position: 0)

    expect {
      described_class.start_workflow(main_grader_workflow)
    }.to change { grader_fanout.runs.count }.by(1)
    expect(main_grader_workflow.reload.artifact("start_blocked_reason")).to be_nil
  end

  it "starts the workflow when the formerly urgent job is now closed" do
    create_urgent_job!(state: "closed")

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "clears the urgent_job_active block reason when no longer blocked" do
    create_urgent_job!(state: "closed")
    workflow.update!(artifacts: { "start_blocked_reason" => "urgent_job_active" })

    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
  end
end

RSpec.describe StepDispatcher, "main_health queue gate" do
  include ActiveJob::TestHelper

  let(:job_model) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job_model, trigger_kind: "initial") }
  let!(:s1) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s2) { Step.create!(workflow: workflow, kind: "pr_open", position: 1) }

  before { s1.update!(next_step_id: s2.id) }

  def break_main!
    job_model.repository.update!(ci_health: "broken", landing_paused: true)
  end

  it "does not create a Run when the repository main_health is broken and landing is paused" do
    break_main!
    expect {
      described_class.start_workflow(workflow)
    }.not_to change { Run.count }
    expect(workflow.reload).to be_queued
  end

  it "logs a warning when main is broken and the workflow is left queued" do
    break_main!
    expect(Rails.logger).to receive(:warn).with(include("main_branch_broken"))
    described_class.start_workflow(workflow)
  end

  it "backs off repeated main-health blocked starts" do
    break_main!
    travel_to(Time.zone.parse("2026-07-15 12:00:00 UTC")) do
      expect(Rails.logger).to receive(:warn).once.with(include("main_branch_broken"))

      described_class.start_workflow(workflow)
      next_check_at = workflow.reload.artifact("start_blocked_next_check_at")

      described_class.start_workflow(workflow)

      expect(workflow.reload.artifact("start_blocked_reason")).to eq("main_branch_broken")
      expect(workflow.artifact("start_blocked_next_check_at")).to eq(next_check_at)
    end
  end

  it "starts the workflow when broken main has been manually unpaused" do
    job_model.repository.update!(ci_health: "broken", landing_paused: false)

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow when landing is paused and main_health is inconclusive" do
    job_model.repository.update!(ci_health: "not_configured", grader_health: "inconclusive", landing_paused: true)

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow when landing is paused and main_health is unknown" do
    job_model.repository.update!(ci_health: "unknown", grader_health: "unknown", landing_paused: true)

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow when main branch health checking is disabled" do
    job_model.repository.update!(main_branch_health_enabled: false, ci_health: "broken", landing_paused: true)

    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow normally when main_health is healthy" do
    job_model.repository.update!(ci_health: "healthy", grader_health: "healthy", landing_paused: true)
    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "starts the workflow normally when main_health is unknown (default)" do
    expect {
      described_class.start_workflow(workflow)
    }.to change { s1.runs.count }.by(1)
  end

  it "does not block rebase workflows even when main is broken" do
    break_main!
    rebase_workflow = Workflow.create!(job: job_model, trigger_kind: "rebase")
    rs1 = Step.create!(workflow: rebase_workflow, kind: "auto_rebase", position: 0)

    expect {
      described_class.start_workflow(rebase_workflow)
    }.to change { rs1.runs.count }.by(1)
  end

  it "does not block stack_rebase workflows even when main is broken" do
    break_main!
    sr_workflow = Workflow.create!(job: job_model, trigger_kind: "stack_rebase")
    rs1 = Step.create!(workflow: sr_workflow, kind: "stack_auto_rebase", position: 0)

    expect {
      described_class.start_workflow(sr_workflow)
    }.to change { rs1.runs.count }.by(1)
  end

  it "does not block a fix-main direct job's initial workflow even when main is broken" do
    break_main!
    fix_job = Factories.job_record(
      user: job_model.user,
      repository: job_model.repository,
      kind: "direct",
      issue_title: MainHealthChangedService::FIX_MAIN_TITLE,
      issue_number: nil,
      state: "queued"
    )
    fix_workflow = Workflow.create!(job: fix_job, trigger_kind: "initial")
    fix_step = Step.create!(workflow: fix_workflow, kind: "implement", position: 0)

    expect {
      described_class.start_workflow(fix_workflow)
    }.to change { fix_step.runs.count }.by(1)
  end
end

RSpec.describe StepDispatcher, "stack_dependencies_not_ready block reason" do
  include ActiveJob::TestHelper

  let(:job_model) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job_model, trigger_kind: "initial") }
  let!(:s1) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s2) { Step.create!(workflow: workflow, kind: "pr_open", position: 1) }

  before { s1.update!(next_step_id: s2.id) }

  it "records stack_dependencies_not_ready as the block reason on a non-rebase workflow" do
    prerequisite = Factories.job(repository: job_model.repository, issue_number: 99)
    JobDependency.create!(job: job_model, depends_on_job: prerequisite, source: "manual")

    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to eq("stack_dependencies_not_ready")
  end

  it "records dependency_failed when a dependency closed unsuccessfully" do
    prerequisite = Factories.job_record(
      repository: job_model.repository,
      issue_number: 99,
      state: "closed",
      closure_reason: "cancelled"
    )
    JobDependency.create!(job: job_model, depends_on_job: prerequisite, source: "manual")

    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to eq("dependency_failed")
  end

  it "clears stack_dependencies_not_ready when the dependency becomes satisfied" do
    prerequisite = Factories.job(repository: job_model.repository, issue_number: 99)
    JobDependency.create!(job: job_model, depends_on_job: prerequisite, source: "manual")
    workflow.update!(artifacts: { "start_blocked_reason" => "stack_dependencies_not_ready" })

    prerequisite.close_with_reason!("pr_merged")
    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
  end

  it "clears stack_dependencies_not_ready and starts when the only blocking dependency is removed" do
    prerequisite = Factories.job(repository: job_model.repository, issue_number: 99)
    dependency = JobDependency.create!(job: job_model, depends_on_job: prerequisite, source: "manual")

    described_class.start_workflow(workflow)
    expect(workflow.reload.artifact("start_blocked_reason")).to eq("stack_dependencies_not_ready")
    expect(s1.runs.count).to eq(0)

    dependency.destroy!

    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
    expect(s1.runs.count).to eq(1)
  end

  it "keeps stack_dependencies_not_ready when another dependency is still unsatisfied" do
    first = Factories.job(repository: job_model.repository, issue_number: 99)
    second = Factories.job(repository: job_model.repository, issue_number: 100)
    removed_dependency = JobDependency.create!(job: job_model, depends_on_job: first, source: "manual")
    JobDependency.create!(job: job_model, depends_on_job: second, source: "manual")

    described_class.start_workflow(workflow)
    removed_dependency.destroy!

    expect(workflow.reload.artifact("start_blocked_reason")).to eq("stack_dependencies_not_ready")
    expect(s1.runs.count).to eq(0)
  end

  it "does not record the block reason on a rebase workflow (rebase is cancelled instead)" do
    prerequisite = Factories.job_record(repository: job_model.repository, issue_number: 99, state: "closed", closure_reason: "pr_closed")
    blocked_job = Factories.job_record(
      user: job_model.user,
      repository: job_model.repository,
      issue_number: 100,
      state: "approved",
      pr_number: 100,
      branch_name: "syrus/issue-100-#{job_model.id}"
    )
    JobDependency.create!(job: blocked_job, depends_on_job: prerequisite, source: "manual")
    rebase = Workflows::Rebase.instantiate(job: blocked_job)

    described_class.start_workflow(rebase)

    expect(rebase.reload).to be_cancelled
    expect(rebase.artifact("start_blocked_reason")).to eq("dependency_failed")
  end

  context "with approved same-Epic fan-in dependency branches" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user) }
    let(:epic) { Factories.epic(user: user, repository: repository, state: "in_progress", epic_dependency_policy: "nonlinear") }
    let(:job_model) { Factories.job_record(user: user, repository: repository, epic: epic, state: "queued", issue_number: 1577) }

    def approved_dependency(issue_number, branch_name, head_sha)
      dependency = Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        state: "approved",
        issue_number: issue_number,
        branch_name: branch_name,
        pr_number: issue_number
      )
      dependency.runs.create!(trigger_kind: "initial", state: "succeeded", head_sha: head_sha)
      dependency
    end

    it "starts the workflow on a prepared combined base when dependency branches merge cleanly" do
      dep_a = approved_dependency(1574, "syrus/issue-1574", "a" * 40)
      dep_b = approved_dependency(1575, "syrus/issue-1575", "b" * 40)
      dep_c = approved_dependency(1576, "syrus/issue-1576", "c" * 40)
      [ dep_a, dep_b, dep_c ].each { |dependency| JobDependency.create!(job: job_model, depends_on_job: dependency, source: "manual") }
      builder = instance_double(JobStackPreparedBaseBuilder)
      allow(JobStackPreparedBaseBuilder).to receive(:new).and_return(builder)
      allow(builder).to receive(:call).and_return(
        JobStackPreparedBaseBuilder::Result.new(
          true,
          "prepared",
          "syrus/prepared-base-#{job_model.id}-#{workflow.id}",
          "d" * 40,
          [],
          "prepared fan-in execution base"
        )
      )

      expect {
        described_class.start_workflow(workflow)
      }.to change { s1.runs.count }.by(1)

      expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
      expect(workflow.artifact("rebase_base_branch")).to eq("syrus/prepared-base-#{job_model.id}-#{workflow.id}")
      expect(workflow.artifact("prepared_stack_base")).to include(
        "succeeded" => true,
        "reason" => "prepared"
      )
    end

    it "records an explicit fan-in blocker when a prepared base cannot be built" do
      dep_a = approved_dependency(1574, "syrus/issue-1574", "a" * 40)
      dep_b = approved_dependency(1575, "syrus/issue-1575", "b" * 40)
      dep_c = approved_dependency(1576, "syrus/issue-1576", "c" * 40)
      [ dep_a, dep_b, dep_c ].each { |dependency| JobDependency.create!(job: job_model, depends_on_job: dependency, source: "manual") }
      builder = instance_double(JobStackPreparedBaseBuilder)
      allow(JobStackPreparedBaseBuilder).to receive(:new).and_return(builder)
      allow(builder).to receive(:call).and_return(
        JobStackPreparedBaseBuilder::Result.new(false, "merge_conflict_or_git_error", nil, nil, [], "conflict in app/models/widget.rb")
      )

      expect {
        described_class.start_workflow(workflow)
      }.not_to change { s1.runs.count }

      expect(workflow.reload.artifact("start_blocked_reason")).to eq("stack_fan_in_base_unavailable")
      expect(workflow.artifact("start_blocked_details")).to include(
        "kind" => "fan_in_base_unavailable",
        "action" => include("Land the sibling dependencies")
      )
      expect(workflow.artifact("start_blocked_details")["dependencies"].map { |dependency| dependency["job_id"] }).to contain_exactly(dep_a.id, dep_b.id, dep_c.id)
    end
  end
end

RSpec.describe StepDispatcher, "job_not_ready_for_execution block reason" do
  include ActiveJob::TestHelper

  let(:job_model) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job_model, trigger_kind: "initial") }
  let!(:s1) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s2) { Step.create!(workflow: workflow, kind: "pr_open", position: 1) }

  before { s1.update!(next_step_id: s2.id) }

  it "records job_not_ready_for_execution when the job is invalid" do
    job_model.update!(validity: "duplicate")

    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to eq("job_not_ready_for_execution")
  end

  it "clears job_not_ready_for_execution when the job becomes valid" do
    job_model.update!(validity: "duplicate")
    workflow.update!(artifacts: { "start_blocked_reason" => "job_not_ready_for_execution" })

    job_model.update!(validity: "valid")
    described_class.start_workflow(workflow)

    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
  end

  describe ".record_start_blocked!" do
    it "sets start_blocked_count to 1 on the first call" do
      described_class.record_start_blocked!(workflow, "urgent_job_active", backoff: 5.minutes)

      expect(workflow.reload.artifact("start_blocked_count")).to eq(1)
    end

    it "increments start_blocked_count on repeated calls for the same reason" do
      described_class.record_start_blocked!(workflow, "urgent_job_active", backoff: 5.minutes)
      described_class.record_start_blocked!(workflow, "urgent_job_active", backoff: 5.minutes)
      described_class.record_start_blocked!(workflow, "urgent_job_active", backoff: 5.minutes)

      expect(workflow.reload.artifact("start_blocked_count")).to eq(3)
    end

    it "resets start_blocked_count to 1 when the reason changes" do
      described_class.record_start_blocked!(workflow, "urgent_job_active", backoff: 5.minutes)
      described_class.record_start_blocked!(workflow, "urgent_job_active", backoff: 5.minutes)
      described_class.record_start_blocked!(workflow, "main_branch_broken", backoff: 5.minutes)

      expect(workflow.reload.artifact("start_blocked_count")).to eq(1)
    end

    it "sets start_blocked_next_check_at based on the backoff" do
      travel_to(Time.zone.parse("2026-08-10 12:00:00 UTC")) do
        described_class.record_start_blocked!(workflow, "urgent_job_active", backoff: 5.minutes)

        expect(workflow.reload.artifact("start_blocked_next_check_at")).to eq("2026-08-10T12:05:00Z")
      end
    end

    it "clears start_blocked_count on clear_start_blocked!" do
      described_class.record_start_blocked!(workflow, "urgent_job_active", backoff: 5.minutes)
      described_class.record_start_blocked!(workflow, "urgent_job_active", backoff: 5.minutes)
      described_class.clear_start_blocked!(workflow, "urgent_job_active")

      expect(workflow.reload.artifact("start_blocked_count")).to be_nil
    end
  end
end
