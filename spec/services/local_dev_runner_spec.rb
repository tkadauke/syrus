require "rails_helper"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe LocalDevRunner do
  let(:user) { Factories.user(github_token: nil, claude_oauth_token: "oat-test") }

  before do
    @data_root = Dir.mktmpdir("syrus-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
    RunJob.agent_runner = method(:agent_runner)
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    RunJob.agent_runner = nil
    FileUtils.rm_rf(@data_root) if @data_root
  end

  it "runs a local checkout through prepare and implement, then writes the diff" do
    Dir.mktmpdir("syrus-local-repo") do |repo|
      seed_local_repo(repo)
      output = File.join(Dir.mktmpdir("syrus-local-output"), "diff.patch")

      expect_any_instance_of(Repository).not_to receive(:authenticated_push_url)

      result = described_class.call(
        path: repo,
        prompt: "Add a local greeting helper.",
        output: output,
        user: user
      )

      expect(result.workflow.trigger_kind).to eq("local_dev")
      expect(result.workflow.steps.pluck(:kind, :state)).to eq([
        [ "prepare", "succeeded" ],
        [ "implement", "succeeded" ]
      ])
      expect(result.job).to be_adhoc
      expect(result.job.branch_name).to eq("syrus/local-#{result.job.id}")
      expect(result.job.pr_number).to be_nil
      expect(result.diff).to include("+def local_greet = 'hello from local dev'")
      expect(File.read(output)).to eq(result.diff)
    ensure
      FileUtils.rm_rf(File.dirname(output)) if output
    end
  end

  def agent_runner(workspace_path:, **_)
    File.write(File.join(workspace_path, "local_feature.rb"),
               "def local_greet = 'hello from local dev'\n")
    AgentInvocation::Result.new(
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: nil,
      session_id: nil
    )
  end

  def seed_local_repo(path)
    sh("git init -q -b main #{path}")
    File.write(File.join(path, ".syrus.yml"), "prepare: []\n")
    File.write(File.join(path, "README.md"), "local fixture\n")
    sh("git -C #{path} add .")
    sh("git -C #{path} commit -q -m 'initial'")
  end

  def sh(cmd)
    out, err, status = Open3.capture3(
      {
        "GIT_AUTHOR_NAME" => "Test",
        "GIT_AUTHOR_EMAIL" => "test@example.com",
        "GIT_COMMITTER_NAME" => "Test",
        "GIT_COMMITTER_EMAIL" => "test@example.com"
      },
      cmd
    )
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?

    out
  end
end
