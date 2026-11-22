require "rails_helper"
require "tmpdir"

# NY29 (decided A): an unpublished stacked Job whose finished work conflicts
# with its restacked parent gets an agent conflict resolution in the same
# workspace. Real git repositories, so the conflict is a real one.
RSpec.describe Steps::StackBaseAgentRebase, :ci_only do
  let(:git) { GitRunner.new(env: { "PATH" => "#{RbConfig::CONFIG.fetch('bindir')}:#{ENV.fetch('PATH')}", "GIT_EDITOR" => "true" }) }
  let(:tmp) { Pathname.new(Dir.mktmpdir("stack-base-agent-rebase")) }
  let(:remote) { tmp.join("remote.git") }
  let(:parent_clone) { tmp.join("parent") }
  let(:child) { tmp.join("child") }
  let(:parent_ref) { "syrus/parent" }
  let(:job) { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude") }
  let(:step) { Step.create!(workflow: workflow, kind: "stack_base_agent_rebase", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial", agent_provider: "claude") }
  let(:handler) { described_class.new(run) }

  after { FileUtils.rm_rf(tmp) }

  def sh(dir, *args) = git.run(*args, chdir: dir.to_s).strip

  def commit(dir, file, content)
    File.write(dir.join(file), content)
    sh(dir, "add", file)
    sh(dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-m", "edit #{file}")
    sh(dir, "rev-parse", "HEAD")
  end

  # Rebases the parent onto a main commit that edits shared.txt, the way a
  # stack restack moves a parent under a running child.
  def restack_parent!(shared_content)
    sh(parent_clone, "checkout", "-q", "main")
    commit(parent_clone, "shared.txt", shared_content)
    sh(parent_clone, "push", "-q", "origin", "main")
    sh(parent_clone, "checkout", "-q", "parent")
    sh(parent_clone, "-c", "user.name=t", "-c", "user.email=t@example.com", "rebase", "main")
    sh(parent_clone, "push", "-q", "--force", "origin", "HEAD:refs/heads/#{parent_ref}")
    sh(parent_clone, "rev-parse", "HEAD")
  end

  before do
    FileUtils.mkdir_p(tmp)
    sh(tmp, "init", "-q", "--bare", "-b", "main", remote.to_s)
    sh(tmp, "clone", "-q", remote.to_s, parent_clone.to_s)
    sh(parent_clone, "checkout", "-q", "-b", "main")
    commit(parent_clone, "shared.txt", "original\n")
    sh(parent_clone, "push", "-q", "origin", "main")
    sh(parent_clone, "checkout", "-q", "-b", "parent")
    commit(parent_clone, "parent.txt", "parent\n")
    sh(parent_clone, "push", "-q", "origin", "HEAD:refs/heads/#{parent_ref}")
    @prepared = sh(parent_clone, "rev-parse", "HEAD")

    sh(tmp, "clone", "-q", "--branch", parent_ref, remote.to_s, child.to_s)
    sh(child, "config", "user.name", "t")
    sh(child, "config", "user.email", "t@example.com")
    sh(child, "checkout", "-q", "-b", "syrus/child")
    @child_head = commit(child, "shared.txt", "child edit\n")

    allow(handler).to receive(:workspace).and_return(double(setup: nil, path: child, branch_name: "syrus/child"))
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(handler).to receive(:authenticated_git).and_yield(remote.to_s)
  end

  def record_conflict!(live)
    workflow.set_artifact!(Steps::PrOpen::StackBaseRebaseConflict::ARTIFACT, {
      "parent_ref" => parent_ref, "prepared_sha" => @prepared, "live_sha" => live,
      "conflicted_files" => [ { "path" => "shared.txt" } ]
    })
  end

  it "lets the agent resolve the conflict and records the live parent as the new base" do
    live = restack_parent!("main edit\n")
    record_conflict!(live)
    expect(handler).to receive(:run_agent) do |prompt:|
      expect(prompt).to include(parent_ref, "syrus/child", "shared.txt", "never been pushed")
      File.write(child.join("shared.txt"), "main edit\nchild edit\n")
      sh(child, "add", "shared.txt")
      sh(child, "rebase", "--continue")
    end

    handler.call

    expect(sh(child, "merge-base", "--is-ancestor", live, "HEAD")).to eq("")
    expect(File.read(child.join("shared.txt"))).to eq("main edit\nchild edit\n")
    expect(workflow.reload.artifact(StackBaseFreshness::PREPARED_ARTIFACT)).to include("ref" => parent_ref, "sha" => live)
    expect(workflow.artifact("stack_base_agent_rebase")).to include("live_sha" => live, "pre_sha" => @child_head)
    expect(run.reload.head_sha).to eq(sh(child, "rev-parse", "HEAD"))
  end

  it "fails when the agent leaves the rebase unresolved" do
    record_conflict!(restack_parent!("main edit\n"))
    allow(handler).to receive(:run_agent)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /still in progress/) { |e|
      expect(e.problem.code).to eq("stack_base_rebase_conflict")
    }
  end

  it "replays without the agent when the parent moved on and the conflict is gone" do
    record_conflict!(restack_parent!("main edit\n"))
    # The parent moves again, now leaving shared.txt as the child left it.
    sh(parent_clone, "checkout", "-q", "main")
    commit(parent_clone, "shared.txt", "child edit\n")
    sh(parent_clone, "push", "-q", "origin", "main")
    sh(parent_clone, "checkout", "-q", "parent")
    sh(parent_clone, "-c", "user.name=t", "-c", "user.email=t@example.com", "rebase", "main")
    sh(parent_clone, "push", "-q", "--force", "origin", "HEAD:refs/heads/#{parent_ref}")
    newest = sh(parent_clone, "rev-parse", "HEAD")
    expect(handler).not_to receive(:run_agent)

    handler.call

    expect(sh(child, "merge-base", "--is-ancestor", newest, "HEAD")).to eq("")
    expect(workflow.reload.artifact(StackBaseFreshness::PREPARED_ARTIFACT)).to include("sha" => newest)
  end

  it "refuses to run without a recorded conflict" do
    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /no recorded stack-base conflict/)
  end
end
