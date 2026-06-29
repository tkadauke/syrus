require "rails_helper"
require "ostruct"

RSpec.describe Workflows do
  let(:job) { Factories.job }

  describe ".for(trigger_kind:)" do
    it "returns the right template class for each known trigger_kind" do
      expect(described_class.for(trigger_kind: "initial")).to    eq(Workflows::Initial)
      expect(described_class.for(trigger_kind: "pr_comment")).to eq(Workflows::PrFeedback)
      expect(described_class.for(trigger_kind: "chat_feedback")).to eq(Workflows::ChatFeedback)
      expect(described_class.for(trigger_kind: "ci_failure")).to eq(Workflows::CiFailure)
      expect(described_class.for(trigger_kind: "rebase")).to     eq(Workflows::Rebase)
      expect(described_class.for(trigger_kind: "stack_rebase")).to eq(Workflows::StackRebase)
      expect(described_class.for(trigger_kind: "auto_merge")).to eq(Workflows::AutoMerge)
      expect(described_class.for(trigger_kind: "retry")).to      eq(Workflows::Retry)
      expect(described_class.for(trigger_kind: "manual")).to     eq(Workflows::Manual)
      expect(described_class.for(trigger_kind: "resume")).to     eq(Workflows::Resume)
    end

    it "raises on an unknown trigger_kind" do
      expect { described_class.for(trigger_kind: "bogus") }.to raise_error(ArgumentError, /trigger_kind/)
    end

    it "accepts a Symbol as well as a String (denormalization)" do
      expect(described_class.for(trigger_kind: :initial)).to eq(Workflows::Initial)
    end
  end

  describe ".instantiate(job:)" do
    it "creates the workflow + chain for Initial in transaction" do
      AppSetting.current.update!(adversarial_review_rounds: 0)

      wf = Workflows::Initial.instantiate(job: job)
      expect(wf).to be_persisted
      expect(wf.trigger_kind).to eq("initial")
      expect(wf.agent_provider).to eq("claude")
      expect(wf.state).to eq("queued")
      expect(wf.steps.pluck(:kind, :position)).to eq([
        [ "prepare", 0 ], [ "implement", 1 ], [ "grader_fanout", 2 ], [ "grader_collect", 3 ], [ "summarize", 4 ], [ "test_plan", 5 ], [ "pr_open", 6 ]
      ])
      expect(wf.chain_template).to include(
        {
          "type" => "retry_until",
          "max_iterations" => AppSetting.grade_max_iterations,
          "repair" => %w[ implement ],
          "check" => %w[ grader_fanout grader_collect ],
          "repair_first" => true
        }
      )
      expect(wf.steps.pluck(:kind)).not_to include("adversarial_review")
    end

    it "inserts the adversarial review loop before the grade loop for Initial when enabled" do
      AppSetting.current.update!(adversarial_review_rounds: 2)

      wf = Workflows::Initial.instantiate(job: job)

      expect(wf.steps.pluck(:kind, :position)).to eq([
        [ "prepare", 0 ],
        [ "implement", 1 ],
        [ "adversarial_review", 2 ],
        [ "implement", 3 ],
        [ "implement", 4 ],
        [ "grader_fanout", 5 ],
        [ "grader_collect", 6 ],
        [ "summarize", 7 ],
        [ "test_plan", 8 ],
        [ "pr_open", 9 ]
      ])
      expect(wf.chain_template).to eq([
        { "type" => "step", "kind" => "prepare" },
        {
          "type" => "retry_until",
          "max_iterations" => 2,
          "repair" => %w[ implement ],
          "check" => %w[ adversarial_review ],
          "repair_first" => true
        },
        { "type" => "step", "kind" => "implement" },
        {
          "type" => "retry_until",
          "max_iterations" => AppSetting.grade_max_iterations,
          "repair" => %w[ implement ],
          "check" => %w[ grader_fanout grader_collect ],
          "repair_first" => true
        },
        { "type" => "step", "kind" => "summarize" },
        { "type" => "step", "kind" => "test_plan" },
        { "type" => "step", "kind" => "pr_open" }
      ])
      expect(wf.steps.where.not(loop_id: nil).pluck(:kind)).to eq(%w[ implement adversarial_review implement grader_fanout grader_collect ])
    end

    it "creates the workflow + chain for Retry with test_plan before pr_open" do
      wf = Workflows::Retry.instantiate(job: job)

      expect(wf).to be_persisted
      expect(wf.trigger_kind).to eq("retry")
      expect(wf.steps.pluck(:kind, :position)).to eq([
        [ "prepare", 0 ], [ "implement", 1 ], [ "grader_fanout", 2 ], [ "grader_collect", 3 ], [ "summarize", 4 ], [ "test_plan", 5 ], [ "pr_open", 6 ]
      ])
    end

    it "omits prepare from Initial when the Job has opted out" do
      job.update!(skip_prepare: true)

      wf = Workflows::Initial.instantiate(job: job)

      expect(wf.steps.pluck(:kind, :position)).to eq([
        [ "implement", 0 ], [ "grader_fanout", 1 ], [ "grader_collect", 2 ], [ "summarize", 3 ], [ "test_plan", 4 ], [ "pr_open", 5 ]
      ])
      expect(wf.steps.where.not(loop_id: nil).pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect ])
      expect(wf.artifacts).to include("prepare_skipped" => true)
    end

    it "omits prepare from Retry when the Job has opted out" do
      job.update!(skip_prepare: true)

      wf = Workflows::Retry.instantiate(job: job)

      expect(wf.steps.pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect summarize test_plan pr_open ])
      expect(wf.steps.where.not(loop_id: nil).pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect ])
      expect(wf.trigger_kind).to eq("retry")
    end

    it "keeps prepare as the first step when repository prepare is enabled" do
      job.repository.update!(prepare_enabled: true)

      wf = Workflows::Initial.instantiate(job: job)

      expect(wf.steps.order(:position).first.kind).to eq("prepare")
    end

    it "skips prepare when repository prepare is disabled" do
      job.repository.update!(prepare_enabled: false)

      wf = Workflows::Initial.instantiate(job: job)

      expect(wf.steps.pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect summarize test_plan pr_open ])
      expect(wf.artifact("prepare_skipped_reason")).to eq("repository_configuration")
    end

    it "skips prepare when the issue requested it by label" do
      job.prepare_skip_reason_override = "issue_label"

      wf = Workflows::Initial.instantiate(job: job)

      expect(wf.steps.pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect summarize test_plan pr_open ])
      expect(wf.artifact("prepare_skipped_reason")).to eq("issue_label")
    end

    it "skips prepare when either the issue label or repository setting requests it" do
      job.repository.update!(prepare_enabled: false)
      job.prepare_skip_reason_override = "issue_label"

      wf = Workflows::Initial.instantiate(job: job)

      expect(wf.steps.pluck(:kind)).not_to include("prepare")
      expect(wf.artifact("prepare_skipped_reason")).to eq("repository_configuration")
    end

    it "writes a system log when prepare is skipped by repository configuration" do
      job.repository.update!(prepare_enabled: false)
      wf = Workflows::Initial.instantiate(job: job)

      run = StepDispatcher.start_workflow(wf)

      expect(run.job_logs.pluck(:kind, :chunk)).to include(
        [ "system", "prepare skipped via repository configuration" ]
      )
    end

    it "records the job's current agent provider on the workflow" do
      job.update!(agent_provider: "codex")
      wf = Workflows::Initial.instantiate(job: job)
      expect(wf.agent_provider).to eq("codex")
    end

    it "wires next_step_id top-down (linear chain)" do
      wf = Workflows::Initial.instantiate(job: job)
      a, b, c, d, e, f, g = wf.steps.order(:position)
      expect(a.next_step).to eq(b)
      expect(b.next_step).to eq(c)
      expect(c.next_step).to eq(d)
      expect(d.next_step).to eq(e)
      expect(e.next_step).to eq(f)
      expect(f.next_step).to eq(g)
      expect(g.next_step).to be_nil
    end

    it "materializes the first iteration of a loop node inside the chain" do
      workflow_class = Class.new(Workflows::Base) do
        steps :prepare,
              Workflows::Loop.new(max_iterations: 5, steps: [ :implement, :summarize ]),
              :pr_open

        def self.trigger_kind = "manual"
      end

      wf = workflow_class.instantiate(job: job)
      steps = wf.steps.order(:position).to_a
      loop_ids = steps.map(&:loop_id)

      expect(steps.map { |step| [ step.kind, step.position, step.iteration ] }).to eq([
        [ "prepare", 0, 1 ],
        [ "implement", 1, 1 ],
        [ "summarize", 2, 1 ],
        [ "pr_open", 3, 1 ]
      ])
      expect(loop_ids[0]).to be_nil
      expect(loop_ids[1]).to be_present
      expect(loop_ids[2]).to eq(loop_ids[1])
      expect(loop_ids[3]).to be_nil

      next_wf = workflow_class.instantiate(job: job)
      expect(next_wf.steps.where(kind: "implement").pick(:loop_id)).not_to eq(loop_ids[1])
    end

    it "allows two non-nested loop nodes in one chain with distinct loop ids" do
      workflow_class = Class.new(Workflows::Base) do
        steps :prepare,
              Workflows::Loop.new(steps: [ :implement ]),
              Workflows::Loop.new(steps: [ :summarize ]),
              :pr_open

        def self.trigger_kind = "manual"
      end

      wf = workflow_class.instantiate(job: job)
      loop_steps = wf.steps.where.not(loop_id: nil).order(:position)

      expect(loop_steps.pluck(:kind)).to eq(%w[ implement summarize ])
      expect(loop_steps.pluck(:loop_id).uniq.size).to eq(2)
    end

    it "rejects nested loop declarations" do
      expect do
        Class.new(Workflows::Base) do
          steps Workflows::Loop.new(
            max_iterations: 3,
            steps: [ Workflows::Loop.new(max_iterations: 2, steps: [ :implement ]) ]
          )
        end
      end.to raise_error(ArgumentError, /nested workflow control nodes/)
    end

    it "rejects mixed nested workflow control declarations" do
      expect do
        Class.new(Workflows::Base) do
          steps Workflows::Loop.new(
            max_iterations: 3,
            steps: [
              Workflows::RetryUntil.new(
                repair: [ :implement ],
                check: [ :grade ]
              )
            ]
          )
        end
      end.to raise_error(ArgumentError, /nested workflow control nodes/)
    end

    it "materializes a RetryUntil node with repair first by default" do
      workflow_class = Class.new(Workflows::Base) do
        steps Workflows::RetryUntil.new(
                max_iterations: 3,
                repair: [ :implement ],
                check: [ :grader_fanout, :grader_collect ]
              ),
              :summarize

        def self.trigger_kind = "manual"
      end

      wf = workflow_class.instantiate(job: job)

      expect(wf.steps.order(:position).pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect summarize ])
      expect(wf.steps.where.not(loop_id: nil).pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect ])
      expect(wf.chain_template).to eq([
        {
          "type" => "retry_until",
          "max_iterations" => 3,
          "repair" => %w[ implement ],
          "check" => %w[ grader_fanout grader_collect ],
          "repair_first" => true
        },
        { "type" => "step", "kind" => "summarize" }
      ])
    end

    it "materializes a RetryUntil node with only check steps when repair_first is false" do
      workflow_class = Class.new(Workflows::Base) do
        steps Workflows::RetryUntil.new(
                max_iterations: 3,
                repair_first: false,
                repair: [ :landing_fix ],
                check: [ :grader_fanout, :grader_collect ]
              ),
              :push

        def self.trigger_kind = "manual"
      end

      wf = workflow_class.instantiate(job: job)

      expect(wf.steps.order(:position).pluck(:kind)).to eq(%w[ grader_fanout grader_collect push ])
      expect(wf.steps.where.not(loop_id: nil).pluck(:kind)).to eq(%w[ grader_fanout grader_collect ])
      expect(wf.chain_template).to eq([
        {
          "type" => "retry_until",
          "max_iterations" => 3,
          "repair" => %w[ landing_fix ],
          "check" => %w[ grader_fanout grader_collect ],
          "repair_first" => false
        },
        { "type" => "step", "kind" => "push" }
      ])
    end

    it "stores the effective chain template on the workflow for later reconstruction" do
      workflow_class = Class.new(Workflows::Base) do
        steps :prepare,
              Workflows::Loop.new(max_iterations: 5, steps: [ :implement, :summarize ]),
              :pr_open

        def self.trigger_kind = "manual"
      end

      wf = workflow_class.instantiate(job: job)

      expect(wf.chain_template).to eq([
        { "type" => "step", "kind" => "prepare" },
        { "type" => "loop", "max_iterations" => 5, "steps" => %w[ implement summarize ] },
        { "type" => "step", "kind" => "pr_open" }
      ])
    end

    it "instantiates PrFeedback with respond → grader_fanout → grader_collect → summarize_amend → push" do
      wf = Workflows::PrFeedback.instantiate(job: job)
      expect(wf.steps.pluck(:kind)).to eq(%w[ prepare respond grader_fanout grader_collect summarize_amend push ])
      expect(wf.steps.where.not(loop_id: nil).pluck(:kind)).to eq(%w[ respond grader_fanout grader_collect ])
      expect(wf.chain_template).to include(
        {
          "type" => "retry_until",
          "max_iterations" => AppSetting.grade_max_iterations,
          "repair" => %w[ respond ],
          "check" => %w[ grader_fanout grader_collect ],
          "repair_first" => true
        }
      )
    end

    it "instantiates ChatFeedback with chat markdown artifacts and the PR feedback chain shape" do
      wf = Workflows::ChatFeedback.instantiate(
        job: job,
        artifacts: { "chat_feedback" => "Please tighten the dashboard copy." },
        agent_provider: "codex"
      )

      expect(wf.trigger_kind).to eq("chat_feedback")
      expect(wf.agent_provider).to eq("codex")
      expect(wf.artifact("chat_feedback")).to eq("Please tighten the dashboard copy.")
      expect(wf.steps.pluck(:kind)).to eq(%w[ prepare respond grader_fanout grader_collect summarize_amend push ])
      expect(wf.steps.where.not(loop_id: nil).pluck(:kind)).to eq(%w[ respond grader_fanout grader_collect ])
      expect(wf.chain_template).to include(
        {
          "type" => "retry_until",
          "max_iterations" => AppSetting.grade_max_iterations,
          "repair" => %w[ respond ],
          "check" => %w[ grader_fanout grader_collect ],
          "repair_first" => true
        }
      )
    end

    it "instantiates CiFailure with analyze_and_fix → summarize_amend → push" do
      wf = Workflows::CiFailure.instantiate(job: job)
      expect(wf.steps.pluck(:kind)).to eq(%w[ prepare analyze_and_fix summarize_amend push ])
    end

    it "instantiates Rebase with auto_rebase → agent_rebase → force_push" do
      wf = Workflows::Rebase.instantiate(job: job)
      expect(wf.steps.pluck(:kind)).to eq(%w[ auto_rebase agent_rebase force_push ])
    end

    it "captures the live PR base target for Rebase workflows" do
      pr = OpenStruct.new(base: OpenStruct.new(ref: "syrus/issue-1-2", sha: "base-sha"))

      wf = Workflows::Rebase.instantiate(job: job, pr: pr)

      expect(wf.artifact("rebase_base_branch")).to eq("syrus/issue-1-2")
      expect(wf.artifact("rebase_base_sha")).to eq("base-sha")
    end

    it "instantiates StackRebase with the full ordered stack" do
      child = Factories.job_record(
        user: job.user,
        repository: job.repository,
        issue_number: 43,
        pr_number: 8,
        branch_name: "syrus/issue-43-2",
        parent_job: job
      )
      grandchild = Factories.job_record(
        user: job.user,
        repository: job.repository,
        issue_number: 44,
        pr_number: 9,
        branch_name: "syrus/issue-44-3",
        parent_job: child
      )
      job.update!(pr_number: 7, branch_name: "syrus/issue-42-1")
      pr = OpenStruct.new(base: OpenStruct.new(ref: "main", sha: "main-sha"))

      wf = Workflows::StackRebase.instantiate(job: job, pr: pr)

      expect(wf.trigger_kind).to eq("stack_rebase")
      expect(wf.steps.pluck(:kind)).to eq(%w[ stack_auto_rebase stack_agent_rebase stack_force_push ])
      expect(wf.artifact("stack_rebase_jobs").map { |entry| entry["job_id"] }).to eq([ job.id, child.id, grandchild.id ])
      expect(wf.artifact("stack_rebase_jobs").map { |entry| entry["branch_name"] }).to eq([
        "syrus/issue-42-1",
        "syrus/issue-43-2",
        "syrus/issue-44-3"
      ])
      expect(wf.artifact("rebase_base_branch")).to eq("main")
      expect(wf.artifact("rebase_base_sha")).to eq("main-sha")
    end

    it "instantiates AutoMerge with an early mergeability preflight before prepare and final grade gate" do
      wf = Workflows::AutoMerge.instantiate(job: job)
      expect(wf.steps.pluck(:kind)).to eq(%w[ mergeability_preflight prepare grader_fanout grader_collect push auto_merge ])
      expect(wf.steps.where.not(loop_id: nil).pluck(:kind)).to eq(%w[ grader_fanout grader_collect ])
      expect(wf.chain_template).to include(
        { "type" => "step", "kind" => "mergeability_preflight" },
        { "type" => "step", "kind" => "prepare" },
        {
          "type" => "retry_until",
          "max_iterations" => AppSetting.grade_max_iterations,
          "repair" => %w[ landing_fix ],
          "check" => %w[ grader_fanout grader_collect ],
          "repair_first" => false
        }
      )
    end

    it "instantiates Manual with a single 'manual' step" do
      wf = Workflows::Manual.instantiate(job: job)
      expect(wf.steps.pluck(:kind)).to eq(%w[ manual ])
      expect(wf.steps.first.next_step).to be_nil
    end

    it "rolls back the workflow + steps if any step creation fails" do
      # Eager-eval the factory before stubbing — Job#after_create_commit
      # calls Workflows::Initial.instantiate too, and that should be
      # allowed to succeed normally; we only want the stub active for
      # the explicit instantiate call below.
      job
      baseline_wf = Workflow.where(job: job).count
      baseline_step = Step.count

      allow(Step).to receive(:create!).and_call_original
      allow(Step).to receive(:create!).with(hash_including(kind: "pr_open"))
                                      .and_raise(ActiveRecord::RecordInvalid.new(Step.new))

      expect { Workflows::Initial.instantiate(job: job) }
        .to raise_error(ActiveRecord::RecordInvalid)

      # No new workflow / steps should have been persisted by the
      # failing instantiate.
      expect(Workflow.where(job: job).count).to eq(baseline_wf)
      expect(Step.count).to eq(baseline_step)
    end
  end
end
