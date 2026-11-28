require "rails_helper"

RSpec.describe FailureProblems do
  def transient_git_error
    GitRunner::GitError.new(%w[fetch origin main], 128, "fatal: early EOF\nfatal: fetch-pack: invalid index-pack output")
  end

  def missing_ref_git_error
    GitRunner::GitError.new(%w[fetch origin feature], 128, "fatal: couldn't find remote ref refs/heads/feature")
  end

  def github_504
    Octokit::Error.from_response(method: :post, url: "https://api.github.com/repos/acme/widgets/pulls", status: 504,
                                 response_headers: {}, body: "")
  end

  def raised_from(cause)
    raise cause
  rescue StandardError
    begin
      yield
    rescue StandardError => e
      e
    end
  end

  describe ".for_exception" do
    it "describes a GitError and an Octokit error from their own structure" do
      expect(described_class.for_exception(transient_git_error).code).to eq("git_transport_transient")
      expect(described_class.for_exception(github_504).code).to eq("github_api_transient")
    end

    it "looks through a wrapper that is not a StepFailed to the git failure it wraps" do
      wrapped = raised_from(transient_git_error) do
        raise WorkflowSourceSnapshots::InfrastructureStateError, "immutable source checkout missing ref"
      end

      expect(described_class.for_exception(wrapped).code).to eq("git_transport_transient")
    end

    it "makes no claim about an exception with no structured cause" do
      expect(described_class.for_exception(RuntimeError.new("boom"))).to be_nil
      expect(described_class.for_exception(nil)).to be_nil
    end
  end

  describe "a StepFailed raised while handling a git or GitHub failure" do
    it "declares the underlying failure when the step declared nothing" do
      error = raised_from(missing_ref_git_error) { raise Steps::Base::StepFailed, "stack_agent_rebase: could not fetch" }

      expect(error.problem.code).to eq("git_ref_missing")
    end

    it "declares a wrapped GitHub 5xx retryable" do
      error = raised_from(github_504) { raise Steps::Base::StepFailed, "auto_merge: GitHub merge failed: 504" }

      expect(error.problem.code).to eq("github_api_transient")
      expect(error.problem).to be_retryable
    end

    it "keeps the step's own declaration over its cause" do
      error = raised_from(transient_git_error) do
        raise Steps::Base::StepFailed.new("merge_train: rebase not completed", problem_code: :merge_train_rebase_conflict)
      end

      expect(error.problem.code).to eq("merge_train_rebase_conflict")
    end

    it "declares nothing for a StepFailed that was not raised from a failure" do
      expect(Steps::Base::StepFailed.new("plain").problem).to be_nil
    end
  end

  describe "CaptureRunDiagnostic" do
    let(:run) { Factories.job.initial_run }

    it "records the declared code of a GitError that escaped the step" do
      CaptureRunDiagnostic.capture(run, transient_git_error)

      expect(run.reload.run_diagnostic).to have_attributes(error_class: "GitRunner::GitError", problem_code: "git_transport_transient")
    end

    it "records the declared code of an Octokit error that escaped the step" do
      CaptureRunDiagnostic.capture(run, github_504)

      expect(run.reload.run_diagnostic).to have_attributes(error_class: "Octokit::ServerError", problem_code: "github_api_transient")
    end

    it "records the cause-derived code of a wrapping StepFailed" do
      error = raised_from(missing_ref_git_error) { raise Steps::Base::StepFailed, "pr_open: fetch failed" }
      CaptureRunDiagnostic.capture(run, error)

      expect(run.reload.run_diagnostic.problem_code).to eq("git_ref_missing")
    end
  end
end
