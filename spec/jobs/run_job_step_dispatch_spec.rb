require "rails_helper"

# RunJob's step-dispatch path. Stubs the handler so we don't shell
# out to claude / git in these tests — the handler invocations
# themselves are exercised by the dedicated handler specs (and
# end-to-end via the existing run_job_spec for the legacy path).
RSpec.describe RunJob, "step-dispatch path" do
  let(:job)      { Factories.job(issue_number: 42) }
  let!(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let!(:s_implement) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:s_summarize) { Step.create!(workflow: workflow, kind: "summarize", position: 1) }
  let!(:s_pr_open)   { Step.create!(workflow: workflow, kind: "pr_open",   position: 2) }

  before do
    s_implement.update!(next_step_id: s_summarize.id)
    s_summarize.update!(next_step_id: s_pr_open.id)
  end

  # Replace each handler with a stub that just succeeds. Specific
  # handlers are tested in their own files.
  let(:noop_handler_class) do
    Class.new(Steps::Base) do
      def call; nil; end
    end
  end

  before do
    allow(Steps).to receive(:handler_for).and_return(noop_handler_class)
  end

  it "drives the first step's Run through Steps.handler_for and succeeds" do
    run = StepDispatcher.start_workflow(workflow)
    expect(run.step).to eq(s_implement)
    expect(run.state).to eq("queued")

    described_class.perform_now(run.id)

    run.reload
    s_implement.reload
    expect(run.state).to eq("succeeded")
    expect(s_implement.state).to eq("succeeded")
  end

  it "transitions Workflow to running and drives the chain through to succeeded in one perform" do
    # With inline-chain dispatch, RunJob.perform doesn't bounce
    # back through SQ between steps — it loops over the chain in
    # one worker invocation. So the Workflow goes queued →
    # running → succeeded inside the same perform_now call when
    # every handler returns cleanly.
    run = StepDispatcher.start_workflow(workflow)
    expect(workflow.reload.state).to eq("queued")
    described_class.perform_now(run.id)
    expect(workflow.reload.state).to eq("succeeded")
  end

  it "advances through every Step in the chain in a single perform invocation" do
    StepDispatcher.start_workflow(workflow)
    described_class.perform_now(s_implement.runs.last.id)

    # All three steps got their Runs created + succeeded in this
    # one invocation — depth-first per Workflow.
    expect(s_implement.reload.state).to eq("succeeded")
    expect(s_summarize.reload.runs.count).to eq(1)
    expect(s_summarize.runs.last.state).to eq("succeeded")
    expect(s_pr_open.reload.runs.count).to eq(1)
    expect(s_pr_open.runs.last.state).to eq("succeeded")
  end

  it "does NOT enqueue downstream Runs through SolidQueue (inline dispatch)" do
    StepDispatcher.start_workflow(workflow)
    # The first Run was enqueued by start_workflow's normal path.
    # Reset the queue so we only see new enqueues from inline-chain
    # dispatch (there should be none).
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    expect {
      described_class.perform_now(s_implement.runs.last.id)
    }.not_to have_enqueued_job(RunJob)
  end

  it "does not overwrite a terminal state applied while the handler is running" do
    externally_failed_handler = Class.new(Steps::Base) do
      def call
        external = Run.find(run.id)
        external.fail!
        external.save!
      end
    end
    allow(Steps).to receive(:handler_for).and_return(externally_failed_handler)

    run = StepDispatcher.start_workflow(workflow)
    described_class.perform_now(run.id)

    expect(run.reload.state).to eq("failed")
    expect(s_implement.reload.state).to eq("failed")
    expect(workflow.reload.state).to eq("failed")
    expect(s_summarize.reload.runs).to be_empty
  end

  it "continues inline after a Try failure branch expands" do
    try_workflow = workflow_with_try_push_branch
    handler_class = Class.new(Steps::Base) do
      define_method(:call) do
        if step.kind == "push"
          step.update!(
            details: step.details.merge(
              "failure_code" => Steps::Push::RemoteBranchAdvancedRebaseConflict::FAILURE_CODE
            )
          )
          raise Steps::Push::RemoteBranchAdvancedRebaseConflict, "remote branch advanced"
        end
      end
    end
    allow(Steps).to receive(:handler_for).and_return(handler_class)

    StepDispatcher.start_workflow(try_workflow)
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear

    expect {
      described_class.perform_now(try_workflow.first_step.runs.last.id)
    }.not_to have_enqueued_job(RunJob)

    expect(try_workflow.reload).to be_succeeded
    expect(try_workflow.failure_count).to eq(0)
    expect(try_workflow.steps.order(:position).pluck(:kind, :state)).to eq([
      [ "summarize_amend", "succeeded" ],
      [ "push", "failed" ],
      [ "push_agent_rebase", "succeeded" ],
      [ "grader_fanout", "succeeded" ],
      [ "grader_collect", "succeeded" ],
      [ "push_after_rebase", "succeeded" ]
    ])
  end

  describe "adversarial review loop integration" do
    it "runs one review round, then resumes the final implement from the implement session" do
      AppSetting.current.update!(adversarial_review_rounds: 1)
      review_job = Factories.job_record(issue_number: 77, state: "queued")
      review_workflow = Workflows::Initial.instantiate(job: review_job)
      observed_parents = []

      install_adversarial_loop_handlers(observed_parents)

      StepDispatcher.start_workflow(review_workflow)
      described_class.perform_now(review_workflow.first_step.runs.last.id)

      expect(review_workflow.reload).to be_succeeded
      expect(review_workflow.steps.order(:position).pluck(:kind)).to eq(%w[
        prepare implement adversarial_review implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open
      ])
      expect(observed_parents).to include(
        [ "implement_review", 1, nil ],
        [ "adversarial_review", 1, nil ],
        [ "implement_final", 1, "implement-1" ]
      )
      expect(observed_parents.none? { |role, _, parent| role == "adversarial_review" && parent&.start_with?("implement") }).to be(true)
    end

    it "runs two review rounds with isolated reviewer session continuity" do
      AppSetting.current.update!(adversarial_review_rounds: 2)
      review_job = Factories.job_record(issue_number: 78, state: "queued")
      review_workflow = Workflows::Initial.instantiate(job: review_job)
      observed_parents = []

      install_adversarial_loop_handlers(observed_parents)

      StepDispatcher.start_workflow(review_workflow)
      described_class.perform_now(review_workflow.first_step.runs.last.id)

      expect(review_workflow.reload).to be_succeeded
      expect(review_workflow.steps.order(:position).pluck(:kind, :iteration)).to eq([
        [ "prepare", 1 ],
        [ "implement", 1 ],
        [ "adversarial_review", 1 ],
        [ "implement", 2 ],
        [ "adversarial_review", 2 ],
        [ "implement", 1 ],
        [ "grader_fanout", 1 ],
        [ "grader_collect", 1 ],
        [ "coverage_analyze", 1 ],
        [ "summarize", 1 ],
        [ "test_plan", 1 ],
        [ "pr_open", 1 ]
      ])
      expect(observed_parents).to include(
        [ "implement_review", 1, nil ],
        [ "adversarial_review", 1, nil ],
        [ "implement_review", 2, "implement-1" ],
        [ "adversarial_review", 2, "review-1" ],
        [ "implement_final", 1, "implement-2" ]
      )
      expect(observed_parents).not_to include([ "adversarial_review", 2, "implement-2" ])
    end

    it "hard-fails when the adversarial reviewer crashes and does not loop" do
      AppSetting.current.update!(adversarial_review_rounds: 2)
      review_job = Factories.job_record(issue_number: 79, state: "queued")
      review_workflow = Workflows::Initial.instantiate(job: review_job)
      install_adversarial_loop_handlers([], fail_role: "adversarial_review")

      StepDispatcher.start_workflow(review_workflow)

      expect {
        described_class.perform_now(review_workflow.first_step.runs.last.id)
      }.to raise_error(Steps::Base::StepFailed, "reviewer crashed")

      expect(review_workflow.reload).to be_failed
      expect(review_workflow.steps.where(kind: "implement").pluck(:iteration)).to eq([ 1, 1 ])
      expect(review_workflow.steps.where(kind: "adversarial_review").pluck(:iteration, :state)).to eq([
        [ 1, "failed" ]
      ])
    end

    it "hard-fails when the implement step inside the review loop fails" do
      AppSetting.current.update!(adversarial_review_rounds: 2)
      review_job = Factories.job_record(issue_number: 80, state: "queued")
      review_workflow = Workflows::Initial.instantiate(job: review_job)
      install_adversarial_loop_handlers([], fail_role: "implement_review")

      StepDispatcher.start_workflow(review_workflow)

      expect {
        described_class.perform_now(review_workflow.first_step.runs.last.id)
      }.to raise_error(Steps::Base::StepFailed, "implement crashed")

      expect(review_workflow.reload).to be_failed
      expect(review_workflow.steps.where(kind: "adversarial_review").first.runs).to be_empty
    end
  end

  describe "failure handling" do
    let(:failing_handler_class) do
      Class.new(Steps::Base) do
        def call; raise Steps::Base::StepFailed, "agent broke"; end
      end
    end

    before { allow(Steps).to receive(:handler_for).and_return(failing_handler_class) }

    it "marks the Run + Step failed and increments the Workflow's failure_count" do
      StepDispatcher.start_workflow(workflow)
      run = s_implement.runs.last

      expect { described_class.perform_now(run.id) }.to raise_error(Steps::Base::StepFailed)

      run.reload
      s_implement.reload
      workflow.reload
      expect(run.state).to eq("failed")
      expect(s_implement.state).to eq("failed")
      expect(workflow.failure_count).to eq(1)
    end

    it "does NOT increment Job.failure_count (per-Workflow accounting now)" do
      StepDispatcher.start_workflow(workflow)
      expect {
        described_class.perform_now(s_implement.runs.last.id)
      }.to raise_error(Steps::Base::StepFailed)
      expect(job.reload.failure_count).to eq(0)
    end

    it "auto-fails the Workflow when failure_count crosses AppSetting.max_job_failures" do
      cap = AppSetting.max_job_failures

      cap.times do |i|
        # Fresh queued step+run for each retry attempt
        if i > 0
          fresh_step = Step.create!(workflow: workflow, kind: "manual", position: 100 + i)
          run = fresh_step.runs.create!(job: job, trigger_kind: "initial")
        else
          StepDispatcher.start_workflow(workflow)
          run = s_implement.runs.last
        end
        described_class.perform_now(run.id) rescue nil
      end

      expect(workflow.reload).to be_failed
    end

    it "captures a RunDiagnostic on step failure" do
      StepDispatcher.start_workflow(workflow)
      run = s_implement.runs.last
      expect {
        described_class.perform_now(run.id)
      }.to raise_error(Steps::Base::StepFailed)
      diag = run.reload.run_diagnostic
      expect(diag).to be_present
      expect(diag.error_class).to eq("Steps::Base::StepFailed")
      expect(diag.error_message).to include("agent broke")
    end

    it "continues inline when a failed grade step has loop budget remaining" do
      loop_wf = Workflow.create!(
        job: job,
        trigger_kind: "manual",
        chain_template: [
          { "type" => "loop", "max_iterations" => 2, "steps" => %w[ implement grade ] },
          { "type" => "step", "kind" => "summarize" },
          { "type" => "step", "kind" => "pr_open" }
        ]
      )
      implement = Step.create!(workflow: loop_wf, kind: "implement", position: 0, loop_id: "loop-a")
      grade = Step.create!(workflow: loop_wf, kind: "grade", position: 1, loop_id: "loop-a")
      summarize = Step.create!(workflow: loop_wf, kind: "summarize", position: 2)
      pr_open = Step.create!(workflow: loop_wf, kind: "pr_open", position: 3)
      implement.update!(next_step_id: grade.id)
      grade.update!(next_step_id: summarize.id)
      summarize.update!(next_step_id: pr_open.id)

      grade_attempts = 0
      handler_class = Class.new(Steps::Base) do
        define_method(:call) do
          if step.kind == "implement"
            ClaudeSession.create!(run: run, session_id: "S-#{run.iteration}", transcript_jsonl: "{}\n")
          elsif step.kind == "grade"
            grade_attempts += 1
            raise Steps::Base::StepFailed, "grade failed" if grade_attempts == 1
          end
        end
      end
      allow(Steps).to receive(:handler_for).and_return(handler_class)

      StepDispatcher.start_workflow(loop_wf)
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear

      expect {
        described_class.perform_now(implement.runs.last.id)
      }.not_to have_enqueued_job(RunJob)

      second_implement = loop_wf.reload.steps.find_by!(kind: "implement", iteration: 2)
      expect(second_implement.runs.last.parent_session_id).to eq("S-1")
      expect(loop_wf).to be_succeeded
      expect(grade_attempts).to eq(2)
    end
  end

  describe "guards" do
    it "abandons the Run as cancelled if the Workflow is already terminal" do
      workflow.update!(state: "succeeded")
      StepDispatcher.start_workflow(workflow)
      run = s_implement.runs.last
      described_class.perform_now(run.id)
      expect(run.reload.state).to eq("cancelled")
    end

    it "abandons the Run as cancelled if the Step is already terminal" do
      StepDispatcher.start_workflow(workflow)
      Step.suppress_cancel_cascade do
        s_implement.update!(state: "cancelled", started_at: 1.minute.ago, finished_at: Time.current)
      end
      run = s_implement.runs.last
      described_class.perform_now(run.id)
      expect(run.reload.state).to eq("cancelled")
    end

    it "fails the Run with worker_died on re-entrancy (run already running)" do
      StepDispatcher.start_workflow(workflow)
      run = s_implement.runs.last
      run.update!(state: "running", started_at: 1.hour.ago)
      described_class.perform_now(run.id)
      expect(run.reload.state).to eq("failed")
      expect(run.agent_outcome).to eq("worker_died")
    end

    it "reconciles a completed pr_open run on re-entrancy instead of failing it" do
      job.update!(state: "running", pr_number: 123, branch_name: "syrus/issue-42-#{job.id}")
      workflow.update!(state: "running", started_at: 5.minutes.ago)
      s_implement.update_columns(state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
      s_summarize.update_columns(state: "succeeded", started_at: 4.minutes.ago, finished_at: 3.minutes.ago)
      s_pr_open.update_columns(state: "running", started_at: 2.minutes.ago)
      run = s_pr_open.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
      run.update!(state: "running", started_at: 2.minutes.ago, last_heartbeat_at: 2.minutes.ago)
      JobLog.append!(run: run, chunk: 'pr_open: opened PR #123 ("Add greeting helper")')

      described_class.perform_now(run.id)

      expect(run.reload).to be_succeeded
      expect(s_pr_open.reload).to be_succeeded
      expect(workflow.reload).to be_succeeded
      expect(job.reload).to be_implemented
    end

    it "refuses to execute a Run whose explicit owner does not match the Job owner" do
      other_user = Factories.user
      run = StepDispatcher.start_workflow(workflow)
      run.update_columns(user_id: other_user.id)

      described_class.perform_now(run.id)

      expect(run.reload.state).to eq("failed")
      expect(run.agent_outcome).to eq("execution_owner_mismatch")
      expect(Steps).not_to have_received(:handler_for)
    end
  end

  def install_adversarial_loop_handlers(observed_parents, fail_role: nil)
    noop_handler = Class.new(Steps::Base) do
      def call; nil; end
    end

    implement_handler = Class.new(Steps::Implement) do
      define_method(:call) do
        role = step.next_step&.kind == "adversarial_review" ? "implement_review" : "implement_final"
        raise Steps::Base::StepFailed, "implement crashed" if fail_role == role

        observed_parents << [ role, step.iteration, parent_session_id ]
        ClaudeSession.create!(
          run: run,
          session_id: role == "implement_review" ? "implement-#{step.iteration}" : "implement-final",
          transcript_jsonl: "{}\n"
        )
      end
    end

    review_handler = Class.new(Steps::AdversarialReview) do
      define_method(:call) do
        raise Steps::Base::StepFailed, "reviewer crashed" if fail_role == "adversarial_review"

        observed_parents << [ "adversarial_review", step.iteration, parent_session_id ]
        ClaudeSession.create!(
          run: run,
          session_id: "review-#{step.iteration}",
          transcript_jsonl: "{}\n"
        )
      end
    end

    allow(Steps).to receive(:handler_for) do |kind|
      case kind
      when "implement"
        implement_handler
      when "adversarial_review"
        review_handler
      else
        noop_handler
      end
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
        }
      ]
    ).tap do |wf|
      summarize = Step.create!(workflow: wf, kind: "summarize_amend", position: 0)
      push = Step.create!(workflow: wf, kind: "push", position: 1, details: { "try_id" => try_id })
      summarize.update!(next_step_id: push.id)
    end
  end
end
