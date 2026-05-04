require "rails_helper"
require "tmpdir"
require "open3"

RSpec.describe Steps::Summarize do
  let(:job)      { Factories.job }   # issue_number: 42
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step)     { Step.create!(workflow: workflow, kind: "summarize", position: 0) }
  let(:run)      do
    Run.create!(job: job, step: step, trigger_kind: "initial").tap { |r| r.start!; r.save! }
  end
  let(:handler) { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-summarize") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    # Seed a git repo with a real-file implement commit (not --allow-empty;
    # git refuses to amend an empty commit without --allow-empty, and the
    # production implement step always writes at least one file).
    git_env = {
      "GIT_AUTHOR_NAME"     => "Test",
      "GIT_AUTHOR_EMAIL"    => "test@test.com",
      "GIT_COMMITTER_NAME"  => "Test",
      "GIT_COMMITTER_EMAIL" => "test@test.com"
    }
    sh(git_env, "git -c init.defaultBranch=main init -q #{@ws_path}")
    File.write(@ws_path.join("feature.rb"), "def greet = 'hello'\n")
    sh(git_env, "git -C #{@ws_path} add feature.rb")
    sh(git_env, "git -C #{@ws_path} commit -q -m 'Syrus implement step (will be rewritten by summarize)'")

    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path,
                              branch_name: "syrus/issue-42-#{job.id}")
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  # Stub run_agent to write agent_pr_title/body onto the Run
  # (simulates MCP sidecar writing mid-run), then return success.
  def stub_agent(title:, body: nil, summary: nil)
    allow(handler).to receive(:run_agent) do
      run.update!(agent_pr_title: title, agent_pr_body: body, agent_summary: summary)
    end
  end

  def commit_message
    `git -C #{@ws_path} log -1 --format='%B'`.strip
  end

  describe "commit message rewrite" do
    it "amends the placeholder commit subject to the agent-authored pr_title" do
      stub_agent(title: "Add greeting helper", body: "Adds a tiny helper.")
      handler.call
      expect(commit_message).to start_with("Add greeting helper")
    end

    it "includes pr_body in the commit message body when present" do
      stub_agent(title: "Add greeting helper", body: "Adds a tiny helper.")
      handler.call
      expect(commit_message).to include("Adds a tiny helper.")
    end

    it "defensively prepends 'Closes #N' when pr_body does not include it" do
      stub_agent(title: "Add greeting helper", body: "Adds a tiny helper.")
      handler.call
      expect(commit_message).to include("Closes ##{job.issue_number}")
    end

    it "does not double-prepend 'Closes #N' when pr_body already contains it" do
      stub_agent(title: "Add greeting helper",
                 body: "Closes ##{job.issue_number}\n\nAdds a tiny helper.")
      handler.call
      expect(commit_message.scan(/Closes ##{job.issue_number}/).size).to eq(1)
    end

    it "uses only the title when pr_body is blank" do
      stub_agent(title: "Add greeting helper", body: nil)
      handler.call
      expect(commit_message).to eq("Add greeting helper")
    end

    it "does not add 'Closes #N' for cron jobs (no issue_number)" do
      cron_task = ScheduledTask.create!(
        user: job.user, repository: job.repository,
        name: "Sweep dead code", prompt: "Look for dead code.",
        kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
      )
      cron_job = Job.create!(
        user: job.user, repository: job.repository,
        kind: "cron", scheduled_task: cron_task
      )
      cron_workflow = Workflow.create!(job: cron_job, trigger_kind: "initial")
      cron_step     = Step.create!(workflow: cron_workflow, kind: "summarize", position: 0)
      cron_run      = Run.create!(job: cron_job, step: cron_step, trigger_kind: "initial")
                         .tap { |r| r.start!; r.save! }

      cron_handler = described_class.new(cron_run)
      allow(cron_handler).to receive(:workspace).and_return(
        instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, branch_name: "syrus/scheduled-1-2")
      )
      allow(cron_handler).to receive(:run_agent) do
        cron_run.update!(agent_pr_title: "Sweep dead code", agent_pr_body: "Removed unused methods.")
      end

      cron_handler.call
      expect(commit_message).not_to include("Closes #")
    end

    it "raises StepFailed when the agent did not call submit_summary (title blank)" do
      allow(handler).to receive(:run_agent)  # agent bails without calling submit_summary
      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /didn't call submit_summary/)
    end
  end

  def sh(env, cmd)
    out, err, status = Open3.capture3(env, cmd)
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
