require "rails_helper"
require "tmpdir"
require "open3"

RSpec.describe Steps::ApplySuggestions do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) do
    Factories.job(repository: repository).tap do |j|
      j.update!(branch_name: "syrus/issue-42-#{j.id}", pr_number: 7)
    end
  end
  let(:workflow) { Workflows::PrFeedback.instantiate(job: job, artifacts: { "pr_comments" => comments }) }
  let(:step) { workflow.steps.find_by!(kind: "apply_suggestions") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "pr_comment") }
  let(:handler) { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-apply-suggestions") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    git_env = {
      "GIT_AUTHOR_NAME" => "Test",
      "GIT_AUTHOR_EMAIL" => "test@test.com",
      "GIT_COMMITTER_NAME" => "Test",
      "GIT_COMMITTER_EMAIL" => "test@test.com"
    }
    sh(git_env, "git -c init.defaultBranch=main init -q #{@ws_path}")
    FileUtils.mkdir_p(@ws_path.join("lib"))
    File.write(@ws_path.join("lib/greet.rb"), "def greet(name)\n  \"Hello, \#{name}!\"\nend\n")
    sh(git_env, "git -C #{@ws_path} add lib/greet.rb")
    sh(git_env, "git -C #{@ws_path} commit -q -m initial")
    sh(git_env, "git -C #{@ws_path} checkout -q -b #{job.branch_name}")

    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path,
                              branch_name: job.branch_name)
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  describe "#call" do
    let(:comments) do
      [
        {
          "id" => 101,
          "author" => "reviewer",
          "body" => "```suggestion\n  \"Ave, \#{name}!\"\n```",
          "path" => "lib/greet.rb",
          "start_line" => 2,
          "line" => 2,
          "created_at" => Time.current.iso8601
        }
      ]
    end

    it "applies a clean suggestion, commits it, and skips agentic feedback steps when the comment was suggestion-only" do
      handler.call

      expect(File.read(@ws_path.join("lib/greet.rb"))).to eq("def greet(name)\n  \"Ave, \#{name}!\"\nend\n")
      expect(commit_message).to eq("Apply suggested change from reviewer")
      expect(workflow.reload.artifact("applied_suggestions").first).to include(
        "comment_id" => 101,
        "path" => "lib/greet.rb"
      )
      expect(workflow.steps.find_by!(kind: "respond")).to be_cancelled
      expect(workflow.steps.find_by!(kind: "summarize_amend")).to be_cancelled
      expect(workflow.steps.find_by!(kind: "push")).to be_queued
    end

    context "with a multi-line suggestion" do
      let(:comments) do
        [
          {
            "id" => 102,
            "author" => "reviewer",
            "body" => "```suggestion\n  greeting = \"Ave, \#{name}!\"\n  greeting.upcase\n```",
            "path" => "lib/greet.rb",
            "start_line" => 2,
            "line" => 2,
            "created_at" => Time.current.iso8601
          }
        ]
      end

      it "replaces the target range with all suggested lines" do
        handler.call

        expect(File.read(@ws_path.join("lib/greet.rb"))).to eq(
          "def greet(name)\n  greeting = \"Ave, \#{name}!\"\n  greeting.upcase\nend\n"
        )
      end
    end

    context "when suggestions conflict" do
      let(:comments) do
        [
          {
            "id" => 201,
            "author" => "reviewer",
            "body" => "```suggestion\n  \"Ave, \#{name}!\"\n```",
            "path" => "lib/greet.rb",
            "start_line" => 2,
            "line" => 2,
            "created_at" => Time.current.iso8601
          },
          {
            "id" => 202,
            "author" => "reviewer",
            "body" => "```suggestion\n  \"Salve, \#{name}!\"\n```",
            "path" => "lib/greet.rb",
            "start_line" => 2,
            "line" => 2,
            "created_at" => Time.current.iso8601
          }
        ]
      end

      it "records the conflict and leaves the agent path runnable" do
        handler.call

        expect(File.read(@ws_path.join("lib/greet.rb"))).to eq("def greet(name)\n  \"Hello, \#{name}!\"\nend\n")
        expect(workflow.reload.artifact("suggestion_conflicts").first["reason"]).to include("overlaps")
        expect(workflow.steps.find_by!(kind: "respond")).to be_queued
        expect(workflow.artifact("applied_suggestions")).to be_nil
      end
    end

    context "when the comment also has prose" do
      let(:comments) do
        [
          {
            "id" => 301,
            "author" => "reviewer",
            "body" => "This is good, but please also rename the helper.\n\n```suggestion\n  \"Ave, \#{name}!\"\n```",
            "path" => "lib/greet.rb",
            "start_line" => 2,
            "line" => 2,
            "created_at" => Time.current.iso8601
          }
        ]
      end

      it "pre-applies the suggestion but keeps respond queued for the prose" do
        handler.call

        expect(File.read(@ws_path.join("lib/greet.rb"))).to include("Ave")
        expect(workflow.steps.find_by!(kind: "respond")).to be_queued
        expect(workflow.steps.find_by!(kind: "summarize_amend")).to be_queued
      end
    end
  end

  def commit_message
    `git -C #{@ws_path} log -1 --format='%B'`.strip
  end

  def sh(env, cmd)
    out, err, status = Open3.capture3(env, cmd)
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
