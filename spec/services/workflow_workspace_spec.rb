require "rails_helper"
require "tmpdir"

RSpec.describe WorkflowWorkspace do
  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-wfws-bare")) }
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main")
  end
  let(:job) { Factories.job(repository: repository, issue_number: 7) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }

  before do
    seed_remote(bare_remote_dir)
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("file://#{bare_remote_dir}")
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{bare_remote_dir}")
    @data_root = Dir.mktmpdir("syrus-wfws-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(@data_root) if @data_root
  end

  describe ".path_for" do
    it "is keyed on workflow id, lives under workflows/" do
      expect(described_class.path_for(workflow))
        .to eq(Pathname.new(@data_root).join("workflows", workflow.id.to_s))
    end
  end

  describe "#setup" do
    context "fresh workflow (no prior workspace)" do
      it "creates a clone on the workflow's branch" do
        ws = described_class.new(workflow)
        ws.setup
        expect(ws.path).to exist
        head_branch = `git -C #{ws.path} rev-parse --abbrev-ref HEAD`.strip
        expect(head_branch).to eq("syrus/issue-7-#{job.id}")
      end

      it "creates a fresh branch when the target branch isn't on origin" do
        ws = described_class.new(workflow)
        ws.setup
        expect(`git -C #{ws.path} log --oneline | wc -l`.strip.to_i).to be >= 1
      end

      it "checks out an existing branch when one is on origin (follow-up workflow on the same Job)" do
        first_workflow_dir = Pathname.new(@data_root).join("workflows", "_setup")
        sh("git clone -q file://#{bare_remote_dir} #{first_workflow_dir}")
        sh("git -C #{first_workflow_dir} checkout -q -b syrus/issue-7-#{job.id}")
        File.write(first_workflow_dir.join("seeded.rb"), "FROM_PRIOR_WORKFLOW\n")
        sh("git -C #{first_workflow_dir} add .")
        sh("git -C #{first_workflow_dir} -c user.email=t@e -c user.name=t commit -q -m 'seed'")
        sh("git -C #{first_workflow_dir} push -q origin syrus/issue-7-#{job.id}")
        FileUtils.rm_rf(first_workflow_dir)

        job.update!(branch_name: "syrus/issue-7-#{job.id}")
        wf2 = Workflow.create!(job: job, trigger_kind: "pr_comment")
        ws = described_class.new(wf2)
        ws.setup
        expect(ws.path.join("seeded.rb")).to exist
        head_branch = `git -C #{ws.path} rev-parse --abbrev-ref HEAD`.strip
        expect(head_branch).to eq("syrus/issue-7-#{job.id}")
      end
    end

    context "idempotent re-setup (retry within a step)" do
      it "no-ops on a clean tree" do
        ws = described_class.new(workflow)
        ws.setup
        before_log = `git -C #{ws.path} log --oneline`
        ws.setup
        after_log = `git -C #{ws.path} log --oneline`
        expect(after_log).to eq(before_log)
      end

      it "restores the working tree on retry-after-crash (uncommitted edits get blown away)" do
        ws = described_class.new(workflow)
        ws.setup
        File.write(ws.path.join("uncommitted_garbage.rb"), "agent crashed mid-edit")
        File.write(ws.path.join("README.md"), "modified-without-commit") rescue nil
        expect(ws.path.join("uncommitted_garbage.rb")).to exist

        ws.setup  # retry — should restore

        # Untracked file is gone (`git clean -fd`).
        expect(ws.path.join("uncommitted_garbage.rb")).not_to exist
      end

      it "preserves committed work on retry-within-step (the whole point — agent's prior commits survive)" do
        ws = described_class.new(workflow)
        ws.setup
        File.write(ws.path.join("real_work.rb"), "actually committed\n")
        sh("git -C #{ws.path} add real_work.rb")
        sh("git -C #{ws.path} -c user.email=t@e -c user.name=t commit -q -m 'partial work'")

        ws.setup

        expect(ws.path.join("real_work.rb")).to exist
        log = `git -C #{ws.path} log --oneline`
        expect(log).to include("partial work")
      end
    end
  end

  describe "#cleanup" do
    it "removes the workflow's path" do
      ws = described_class.new(workflow)
      ws.setup
      expect(ws.path).to exist
      ws.cleanup
      expect(ws.path).not_to exist
    end

    it "is idempotent on a missing path" do
      ws = described_class.new(workflow)
      expect { ws.cleanup }.not_to raise_error
    end
  end

  describe ".local_diff_for" do
    it "returns nil when the workspace doesn't exist" do
      expect(described_class.local_diff_for(workflow)).to be_nil
    end

    it "returns nil when the workflow isn't failed (e.g. queued)" do
      # workflow starts in queued state; no workspace needed
      expect(described_class.local_diff_for(workflow)).to be_nil
    end

    it "returns nil when cleaned_up_at is set" do
      ws = described_class.new(workflow)
      ws.setup
      workflow.start!; workflow.fail!; workflow.save!
      workflow.update_columns(cleaned_up_at: Time.current)
      expect(described_class.local_diff_for(workflow)).to be_nil
    end

    it "returns nil when workspace exists but has no changes vs default branch" do
      ws = described_class.new(workflow)
      ws.setup
      workflow.start!; workflow.fail!; workflow.save!
      expect(described_class.local_diff_for(workflow)).to be_nil
    end

    it "returns committed diff when there are commits ahead of the default branch" do
      ws = described_class.new(workflow)
      ws.setup
      File.write(ws.path.join("feature.rb"), "def greet; 'hello'; end\n")
      sh("git -C #{ws.path} add feature.rb")
      sh("git -C #{ws.path} commit -q -m 'Add greeting'")
      workflow.start!; workflow.fail!; workflow.save!

      result = described_class.local_diff_for(workflow)
      expect(result).not_to be_nil
      expect(result[:committed]).to include("feature.rb")
      expect(result[:uncommitted]).to be_empty
    end

    it "returns uncommitted status when there are only unstaged files" do
      ws = described_class.new(workflow)
      ws.setup
      File.write(ws.path.join("wip.rb"), "# work in progress\n")
      workflow.start!; workflow.fail!; workflow.save!

      result = described_class.local_diff_for(workflow)
      expect(result).not_to be_nil
      expect(result[:committed]).to be_empty
      expect(result[:uncommitted]).to include("wip.rb")
    end

    it "returns both committed and uncommitted when both are present" do
      ws = described_class.new(workflow)
      ws.setup
      File.write(ws.path.join("committed.rb"), "# committed\n")
      sh("git -C #{ws.path} add committed.rb")
      sh("git -C #{ws.path} commit -q -m 'Done half'")
      File.write(ws.path.join("wip.rb"), "# wip\n")
      workflow.start!; workflow.fail!; workflow.save!

      result = described_class.local_diff_for(workflow)
      expect(result).not_to be_nil
      expect(result[:committed]).to include("committed.rb")
      expect(result[:uncommitted]).to include("wip.rb")
    end

    it "returns nil (swallows error) when git fails rather than raising" do
      # Workspace dir exists but isn't a git repo — git will error.
      bad_path = described_class.path_for(workflow)
      FileUtils.mkdir_p(bad_path)
      workflow.start!; workflow.fail!; workflow.save!
      expect { described_class.local_diff_for(workflow) }.not_to raise_error
      expect(described_class.local_diff_for(workflow)).to be_nil
    end
  end

  describe "Workflow terminal-state cleanup hook" do
    it "tears the workspace down when the Workflow transitions to succeeded" do
      ws = described_class.new(workflow)
      ws.setup
      expect(ws.path).to exist

      workflow.start!
      workflow.succeed!
      workflow.save!

      expect(ws.path).not_to exist
    end

    it "does NOT tear the workspace down on Workflow.fail! (deferred for Retry-from-failed-step)" do
      ws = described_class.new(workflow)
      ws.setup
      workflow.start!
      workflow.fail!
      workflow.save!
      # Workspace stays on disk so the operator can use
      # JobsController#retry_step. cleaned_up_at stays nil.
      expect(ws.path).to exist
      expect(workflow.reload.cleaned_up_at).to be_nil
    end

    it "WorkflowWorkspacePruneJob eventually cleans up failed workflows past retention" do
      ws = described_class.new(workflow)
      ws.setup
      workflow.start!
      workflow.fail!
      workflow.update!(finished_at: (WorkflowWorkspacePruneJob::RETAIN_AFTER_FAILURE + 1.day).ago)
      WorkflowWorkspacePruneJob.perform_now
      expect(ws.path).not_to exist
      expect(workflow.reload.cleaned_up_at).to be_present
    end

    it "tears the workspace down on Workflow.cancel!" do
      ws = described_class.new(workflow)
      ws.setup
      workflow.cancel!
      workflow.save!
      expect(ws.path).not_to exist
    end

    it "logs cleanup start/end to the latest run's JobLog when a run exists" do
      step = workflow.steps.create!(kind: "implement", position: 0)
      run  = step.runs.create!(job: job, trigger_kind: "initial")

      ws = described_class.new(workflow)
      ws.setup
      workflow.start!
      workflow.succeed!
      workflow.save!

      log_chunks = run.job_logs.reload.pluck(:chunk)
      expect(log_chunks).to include(a_string_matching(/cleanup starting/))
      expect(log_chunks).to include(a_string_matching(/cleanup complete/))
    end

    it "cleanup_for does not stamp cleaned_up_at when rm_rf silently leaves the directory" do
      ws = described_class.new(workflow)
      ws.setup
      ws_path = ws.path

      # Simulate rm_rf running without actually removing the directory.
      allow(FileUtils).to receive(:rm_rf).and_call_original
      allow(FileUtils).to receive(:rm_rf).with(ws_path.to_s) { nil }

      described_class.cleanup_for(workflow)

      expect(ws_path).to exist
      expect(workflow.reload.cleaned_up_at).to be_nil
    end

    it "doesn't blow up the state transition if cleanup raises" do
      ws = described_class.new(workflow)
      ws.setup
      ws_path = ws.path.to_s
      # Scope the failure narrowly to the workspace path so the test's
      # own teardown (which also rm_rf's tmp directories) isn't
      # affected.
      allow(FileUtils).to receive(:rm_rf).and_call_original
      allow(FileUtils).to receive(:rm_rf).with(ws_path).and_raise(StandardError, "permissions")
      workflow.start!
      expect { workflow.succeed!; workflow.save! }.not_to raise_error
      expect(workflow.reload).to be_succeeded
    end
  end

  def seed_remote(bare_path)
    Dir.mktmpdir("syrus-wfws-seed") do |seed|
      sh("git init -q -b main #{seed}")
      sh("git -C #{seed} commit --allow-empty -q -m 'initial' --author='Seed <s@e>'")
      FileUtils.mkdir_p(bare_path.dirname)
      sh("git clone -q --bare #{seed} #{bare_path}")
    end
  end

  def sh(cmd)
    out, err, status = Open3.capture3(
      { "GIT_AUTHOR_NAME" => "Seed", "GIT_AUTHOR_EMAIL" => "s@e",
        "GIT_COMMITTER_NAME" => "Seed", "GIT_COMMITTER_EMAIL" => "s@e" },
      cmd
    )
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
