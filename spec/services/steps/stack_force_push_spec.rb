require "rails_helper"

RSpec.describe Steps::StackForcePush do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) do
    Factories.job(
      user: user,
      repository: repository,
      issue_number: 42,
      pr_number: 7,
      branch_name: "syrus/direct-5003"
    )
  end
  let!(:child) do
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 43,
      pr_number: 8,
      branch_name: "syrus/direct-5004",
      parent_job: job
    )
  end
  let(:workflow) { Workflows::StackRebase.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "stack_force_push") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "stack_rebase") }
  let(:handler) { described_class.new(run) }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: nil, path: Pathname.new("/tmp/workspace")) }
  let(:git) { instance_double(GitRunner) }

  before do
    workflow.set_artifact!(StackRebasePlan::AGENT_PUSHES_ARTIFACT, [
      { "branch_name" => child.branch_name, "pre_sha" => "abc123" }
    ])

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:active_installation_for).and_return(nil)
    allow(GithubClient).to receive(:for)
      .with(repository: kind_of(Repository), user: user)
      .and_return(instance_double(GithubClient, access_token: "token"))
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")

    # Both steps that run after the push loop touch GitHub/DB state we don't
    # care about in these push-classification examples.
    allow_any_instance_of(described_class).to receive(:update_pull_request_bases)
    allow_any_instance_of(described_class).to receive(:refresh_stack_footers)
  end

  # RUN-145012 (WF-28645, JOB-5003): stack_force_push pushed syrus/direct-5003
  # cleanly, then the push for syrus/direct-5004 hit a transient GitHub 500
  # ("remote: Internal Server Error" / "! [remote rejected] ... (Internal
  # Server Error)"). The old PUSH_REJECTED_PATTERN's bare "rejected" token
  # matched this and misreported it as "lease rejected ... remote branch moved
  # after Syrus fetched it", discarding the completed stack_agent_rebase
  # conflict-resolution work instead of letting the transient failure surface
  # (and retry) as itself.
  it "fails with a retryable provider_transient Problem instead of misreporting a transient GitHub 5xx push failure as a lease rejection" do
    allow(git).to receive(:run).and_raise(
      GitRunner::GitError.new(
        %w[push],
        1,
        <<~OUTPUT
          remote: Internal Server Error
          To https://github.com/acme/widgets.git
           ! [remote rejected] #{child.branch_name} -> #{child.branch_name} (Internal Server Error)
          error: failed to push some refs to 'https://github.com/acme/widgets.git'
        OUTPUT
      )
    )

    raised = nil
    begin
      handler.call
    rescue Steps::Base::StepFailed => e
      raised = e
    end

    expect(raised).to be_a(Steps::Base::StepFailed)
    expect(raised.problem.code).to eq("provider_transient")
    expect(raised.problem.retryable?).to be(true)

    logs = run.job_logs.pluck(:chunk).join("\n")
    expect(logs).not_to include("lease rejected")
    expect(logs).to include("transient server error")

    # The classification pipeline a real Run failure goes through
    # (RunFailureClassifier reads the declared Problem off the persisted
    # RunDiagnostic) must agree the failure is retryable -- otherwise the
    # workflow terminally fails anyway despite the step declaring otherwise.
    run.create_run_diagnostic!(
      error_class: raised.class.name,
      error_message: raised.message,
      problem_code: raised.problem.code,
      problem_evidence: raised.problem.evidence
    )
    result = RunFailureClassifier.classify(run)
    expect(result.classification).to eq("provider_transient")
    expect(result.retryable).to be(true)
  end

  it "still fails visibly with a lease-rejected StepFailed for a genuine non-fast-forward conflict" do
    allow(git).to receive(:run).and_raise(
      GitRunner::GitError.new(
        %w[push],
        1,
        "! [rejected]        HEAD -> #{child.branch_name} (non-fast-forward)"
      )
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /lease rejected/)
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("remote branch moved")
  end
end
