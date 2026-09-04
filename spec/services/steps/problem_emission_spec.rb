require "rails_helper"

# Steps declare the Problem they failed with, and the layers downstream read
# that declaration instead of regex-matching their way back to it.
#
# The bug this replaces: a step raised prose, and three independent layers --
# RunFailureClassifier, LandingFailureHandler and MergeTrainFailureHandler --
# each kept their own pattern for recovering the meaning. They disagreed. Seven
# of the eleven "rebuild required" / "operator intervention required" messages
# the merge-train steps actually raise matched none of the classifier's
# patterns, and LandingFailureHandler's `\A`-anchored patterns could not match
# the RunJob path at all, because RunJob prefixes the reason with the exception
# class. A train that needed rebuilding was hard-failed instead of deferred.
RSpec.describe "Step problem emission" do
  describe Steps::Base::StepFailed do
    it "carries no problem when the step made no claim" do
      error = described_class.new("something went wrong")

      expect(error.problem).to be_nil
    end

    it "carries the problem a raise site declares, with its evidence" do
      error = described_class.new("boom", problem_code: :merge_train_rebuild_required,
                                          evidence: { merge_train_id: 7 })

      expect(error.problem.code).to eq("merge_train_rebuild_required")
      expect(error.problem.evidence).to eq(merge_train_id: 7)
      expect(error.problem.retryable?).to be(false)
    end

    it "falls back to inference rather than raising on an unknown code" do
      error = described_class.new("boom", problem_code: :no_such_problem)

      expect(error.problem).to be_nil
    end

    it "inherits a code declared on an exception class" do
      expect(Steps::PrOpen::BranchDiverged.new("moved").problem.code).to eq("branch_diverged")
      expect(Steps::MergeTrainLand::BaseMoved.new("moved").problem.code).to eq("merge_train_rebuild_required")
      expect(Steps::Base::AgentGaveUpWaiting.new("gave up").problem.code).to eq("agent_gave_up_waiting")
    end
  end

  describe CaptureRunDiagnostic do
    let(:job) { Factories.job }
    let(:run) { job.initial_run }

    it "records the declared problem beside the raw exception" do
      error = Steps::Base::StepFailed.new("merge_train: rebase for x was not completed",
                                          problem_code: :merge_train_rebase_conflict,
                                          evidence: { branch: "syrus/issue-3" })

      described_class.capture(run, error)

      diagnostic = run.reload.run_diagnostic
      expect(diagnostic.problem_code).to eq("merge_train_rebase_conflict")
      expect(diagnostic.problem_evidence).to eq("branch" => "syrus/issue-3")
    end

    it "leaves the problem blank when the step made no claim" do
      described_class.capture(run, Steps::Base::StepFailed.new("opaque failure"))

      expect(run.reload.run_diagnostic.problem_code).to be_nil
    end

    it "does not fail the capture when the exception is not a step failure" do
      expect { described_class.capture(run, ArgumentError.new("nope")) }.not_to raise_error
      expect(run.reload.run_diagnostic.problem_code).to be_nil
    end
  end

  describe RunFailureClassifier do
    let(:job) { Factories.job }
    let(:run) { job.initial_run }

    it "prefers the step's own declaration over inferring from the message" do
      run.update!(state: "failed")
      run.create_run_diagnostic!(
        error_class: "Steps::Base::StepFailed",
        # Prose that the message-matching branches would read as git corruption.
        error_message: "merge_train_reconcile: working tree is not clean after reconciliation",
        problem_code: "merge_train_rebase_conflict"
      )

      result = described_class.classify(run.reload)

      expect(result.classification).to eq("merge_train_rebase_conflict")
      expect(result.confidence).to eq(1.0)
      expect(result.retryable).to be(false)
    end

    it "still infers from evidence when no problem was declared" do
      run.update!(state: "failed")
      run.create_run_diagnostic!(error_class: "Errno::E2BIG", error_message: "argument list too long")

      expect(described_class.classify(run.reload).classification).to eq("agent_invocation_too_large")
    end
  end

  describe LandingFailureHandler do
    let(:job) { Factories.job }
    let(:run) { job.initial_run }

    before { job.update_columns(state: "landing") }

    # `landing -> approved` keeps the operator's approval so the train can be
    # rebuilt and re-picked automatically; `landing -> implemented` clears it
    # and demands manual re-approval. Getting this wrong is the user-visible
    # cost of the old regex.
    it "defers landing for a declared rebuild, through RunJob's class-prefixed reason" do
      failed_run = job.initial_run
      RunDiagnostic.create!(run: failed_run, error_class: "Steps::Base::StepFailed",
                            error_message: "merge_train_reconcile: integration branch is missing; rebuild required",
                            problem_code: "merge_train_rebuild_required")

      described_class.call(
        job: job,
        # Exactly the shape RunJob builds. The `\A`-anchored legacy patterns
        # cannot match this, which is the bug.
        reason: "Steps::Base::StepFailed: merge_train_reconcile: integration branch is missing; rebuild required",
        run: failed_run
      )

      expect(job.reload.state).to eq("approved")
    end

    it "still fails landing when nothing declared a deferrable problem" do
      failed_run = job.initial_run
      RunDiagnostic.create!(run: failed_run, error_class: "Steps::Base::StepFailed",
                            error_message: "merge_train: GitHub did not report the integration PR as merged")

      described_class.call(job: job,
                           reason: "Steps::Base::StepFailed: merge_train: GitHub did not report the integration PR as merged",
                           run: failed_run)

      expect(job.reload.state).to eq("implemented")
    end
  end

  # The strings above are fixtures; these call the shipping code. A step helper
  # that stops declaring its Problem fails here, which is the check the old
  # pattern list could never make of itself.
  describe "the merge-train step helpers themselves" do
    let(:harness) do
      Class.new(Steps::Base) do
        include Steps::MergeTrainStep
        def initialize; end # rubocop:disable Style/RedundantInitialize
      end.new
    end
    let(:train) { instance_double(MergeTrain, id: 3, integration_branch: nil, integration_sha: nil) }

    it "declares a rebuild when the integration branch is gone" do
      expect { harness.send(:checkout_integration_branch!, nil, train, chdir: "/tmp", context: "merge_train_rebase") }
        .to raise_error(Steps::Base::StepFailed) { |error|
          expect(error.problem.code).to eq("merge_train_rebuild_required")
          expect(error.problem.evidence).to include(context: "merge_train_rebase")
        }
    end

    it "declares a rebuild when the checkout is not on the integration branch" do
      expect { harness.send(:ensure_integration_branch_ref_at_head!, nil, train, chdir: "/tmp", context: "merge_train_rebase") }
        .to raise_error(Steps::Base::StepFailed) { |error|
          expect(error.problem.code).to eq("merge_train_rebuild_required")
        }
    end
  end

  # The regression that motivated all of the above: drive the assertions from
  # the messages the merge-train steps actually raise, so this cannot drift
  # apart from the code the way a hand-written pattern list did.
  describe "merge-train failures the message patterns used to miss" do
    rebuild = "merge_train_rebuild_required"
    conflict = "merge_train_rebase_conflict"

    {
      rebuild => [
        "merge_train: MergeTrain #12 is failed; rebuild required",
        "merge_train_reconcile: integration branch is missing; rebuild required",
        "merge_train_rebase: integration branch is missing; rebuild required",
        "merge_train_rebase: built integration branch syrus/train-1 at abc is unavailable; rebuild required (boom)",
        "merge_train_rebase: checkout is on main, not integration branch syrus/train-1; rebuild required"
      ],
      conflict => [
        "merge_train_reconcile: working tree is not clean after reconciliation",
        "merge_train: integration PR has merge conflicts for PR #9: conflict; operator intervention required"
      ]
    }.each do |code, messages|
      messages.each do |message|
        it "classifies #{message.truncate(60).inspect} as #{code}" do
          job = Factories.job
          run = job.initial_run
          run.update!(state: "failed")
          run.create_run_diagnostic!(error_class: "Steps::Base::StepFailed",
                                     error_message: message, problem_code: code)

          expect(RunFailureClassifier.classify(run.reload).classification).to eq(code)
        end
      end
    end
  end
end
