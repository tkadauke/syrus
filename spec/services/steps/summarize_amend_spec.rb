require "rails_helper"
require "tmpdir"
require "open3"

RSpec.describe Steps::SummarizeAmend do
  let(:user)     { Factories.user(name: "Ada Lovelace", email_address: "ada@example.com") }
  let(:repository) { Factories.repository(user: user) }
  let(:job)      { Factories.job(repository: repository) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "pr_comment") }
  let(:step)     { Step.create!(workflow: workflow, kind: "summarize_amend", position: 0) }
  let(:run)      do
    Run.create!(job: job, step: step, trigger_kind: "pr_comment").tap { |r| r.start!; r.save! }
  end
  let(:handler) { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-summarize-amend") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    git_env = {
      "GIT_AUTHOR_NAME"     => "Test",
      "GIT_AUTHOR_EMAIL"    => "test@test.com",
      "GIT_COMMITTER_NAME"  => "Test",
      "GIT_COMMITTER_EMAIL" => "test@test.com"
    }
    sh(git_env, "git -c init.defaultBranch=main init -q #{@ws_path}")
    sh(git_env, "git -C #{@ws_path} config user.name 'Ada Lovelace'")
    sh(git_env, "git -C #{@ws_path} config user.email 'ada@example.com'")
    File.write(@ws_path.join("feature.rb"), "def greet = 'hello'\n")
    sh(git_env, "git -C #{@ws_path} add feature.rb")
    sh(git_env, "git -C #{@ws_path} commit -q -m 'Syrus respond step placeholder'")

    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path,
                              branch_name: "syrus/issue-42-#{job.id}")
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  def stub_agent(title:, body: nil, summary: nil)
    allow(handler).to receive(:run_agent) do
      run.update!(agent_pr_title: title, agent_pr_body: body, agent_summary: summary)
    end
  end

  def commit_message
    `git -C #{@ws_path} log -1 --format='%B'`.strip
  end

  describe "commit message rewrite" do
    it "amends the placeholder commit subject to the agent-authored title" do
      stub_agent(title: "Address review feedback: tighten docstring", body: "Tightened the docs.")
      handler.call
      expect(commit_message).to start_with("Address review feedback: tighten docstring")
    end

    it "includes amend_commit_body in the message when present" do
      stub_agent(title: "Address review feedback: tighten docstring", body: "Tightened the docs.")
      handler.call
      expect(commit_message).to include("Tightened the docs.")
    end

    it "uses the subject plus human co-author trailer when body is blank" do
      stub_agent(title: "Address review feedback: tighten docstring", body: nil)
      handler.call
      expect(commit_message).to eq("Address review feedback: tighten docstring\n\nCo-Authored-By: Ada Lovelace <ada@example.com>")
    end

    it "does not add 'Closes #N' (follow-up commit, not a PR opener)" do
      stub_agent(title: "Fix lint", body: "Fixed trailing whitespace.")
      handler.call
      expect(commit_message).not_to include("Closes #")
    end

    it "raises StepFailed when the agent did not call submit_summary" do
      allow(handler).to receive(:run_agent)
      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /didn't call submit_summary/)
    end
  end

  def sh(env, cmd)
    out, err, status = Open3.capture3(env, cmd)
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
