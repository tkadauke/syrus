require "rails_helper"

RSpec.describe "stacked-base agentic repair steps" do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job(user: user, repository: repository, issue_number: 42, branch_name: "syrus/issue-42") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude") }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: nil, branch_name: "syrus/issue-42", path: Pathname.new("/tmp/workspace")) }
  let(:git) { instance_double(GitRunner) }
  let(:live) { "b" * 40 }
  let(:prepared) { "a" * 40 }

  before do
    workflow.set_artifact!(StackBaseFreshness::REPAIR_ARTIFACT, {
      "kind" => "rebase_conflict", "parent_ref" => "syrus/issue-41", "live_sha" => live, "prepared_sha" => prepared,
      "conflicting_paths" => [ "app/x.rb" ], "rebase_output" => "CONFLICT (content)",
      "validation_failures" => [ { "command" => "rspec", "output_tail" => "1 failure" } ]
    })
  end

  def handler_for(kind, klass)
    step = Step.create!(workflow: workflow, kind: kind, position: 0)
    run = Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude")
    klass.new(run).tap do |handler|
      allow(handler).to receive(:workspace).and_return(workspace)
      allow(handler).to receive(:streaming_git).and_return(git)
      allow(handler).to receive(:authenticated_git).and_yield("https://example/repo.git")
      allow(handler).to receive(:abort_rebase_if_present)
    end
  end

  describe Steps::StackBaseAgentRebase do
    let(:handler) { handler_for("stack_base_agent_rebase", described_class) }

    before do
      allow(git).to receive(:run).with("fetch", anything, anything, chdir: "/tmp/workspace")
      allow(git).to receive(:run).with("rev-parse", "refs/remotes/origin/syrus/issue-41", chdir: "/tmp/workspace").and_return("#{live}\n")
      allow(git).to receive(:run).with("cat-file", "-e", "#{prepared}^{commit}", chdir: "/tmp/workspace")
      allow(git).to receive(:run).with("status", "--porcelain", chdir: "/tmp/workspace").and_return("")
      allow(git).to receive(:run).with("merge-base", "--is-ancestor", live, "HEAD", chdir: "/tmp/workspace")
      allow(handler).to receive(:rebase_in_progress?).and_return(false)
      allow(handler).to receive(:head_sha).and_return("1" * 40, "2" * 40)
    end

    it "skips the agent when the deterministic retry now rebases cleanly" do
      allow(git).to receive(:run).with("rebase", "--onto", live, prepared, chdir: "/tmp/workspace")
      expect(handler).not_to receive(:run_agent)

      handler.call

      expect(workflow.reload.artifact(StackBaseFreshness::VALIDATION_PENDING_ARTIFACT)).to include("live_sha" => live)
    end

    it "hands the conflict, paths and both SHAs to the agent and never pushes" do
      allow(git).to receive(:run).with("rebase", "--onto", live, prepared, chdir: "/tmp/workspace").and_raise(GitRunner::GitError.new([ "git", "rebase" ], 1, "conflict"))
      expect(git).not_to receive(:run).with("push", any_args)
      expect(handler).to receive(:run_agent) do |prompt:|
        expect(prompt).to include(live, prepared, "app/x.rb", "CONFLICT (content)")
      end

      handler.call
    end

    it "fails when the agent leaves the tree unrebased" do
      allow(git).to receive(:run).with("rebase", "--onto", live, prepared, chdir: "/tmp/workspace").and_raise(GitRunner::GitError.new([ "git", "rebase" ], 1, "conflict"))
      allow(handler).to receive(:run_agent)
      allow(handler).to receive(:rebase_in_progress?).and_return(true)

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /rebase is still in progress/)
    end
  end

  describe Steps::StackBaseValidationRepair do
    let(:handler) { handler_for("stack_base_validation_repair", described_class) }

    before do
      allow(git).to receive(:run).with("status", "--porcelain", chdir: "/tmp/workspace").and_return("")
      allow(handler).to receive(:rebase_in_progress?).and_return(false)
      allow(handler).to receive(:head_sha).and_return("1" * 40, "2" * 40)
    end

    it "gives the agent the grader command and failure output" do
      expect(handler).to receive(:run_agent) do |prompt:|
        expect(prompt).to include("rspec", "1 failure", live)
      end

      handler.call
    end

    it "refuses to hand back a dirty tree" do
      allow(handler).to receive(:run_agent)
      allow(git).to receive(:run).with("status", "--porcelain", chdir: "/tmp/workspace").and_return(" M app/x.rb")

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /not clean/)
    end
  end
end
