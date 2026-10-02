# frozen_string_literal: true

require "capybara"
require "fileutils"
require "json"
require "open3"
require "rails_helper"
require "tmpdir"

RSpec.describe "Syrus CLI inside workflow runtime", :ci_only do
  self.use_transactional_tests = false

  let(:home) { Dir.mktmpdir("syrus-cli-home") }
  let(:workspace_path) { Pathname.new(Dir.mktmpdir("syrus-cli-workspace")) }
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job_with_run(
      repository: repository,
      user: user,
      issue_number: 123,
      issue_title: "Runtime CLI smoke",
      state: "running",
      workflow_attrs: { state: "running" },
      step_attrs: { state: "running" },
      run_attrs: { state: "running", agent_provider: "claude" }
    )
  end

  after do
    FileUtils.rm_rf(home)
    FileUtils.rm_rf(workspace_path)
    cleanup_records
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "executes the real CLI with invocation-context auth and no human credentials file" do
    @job = job
    @repository = repository
    @user = user
    run = job.runs.first
    captured = nil

    server = nil
    without_vcr do
      server = Capybara::Server.new(Rails.application)
      server.boot
    end

    around_env("SYRUS_APP_HOST" => server.base_url) do
      RunJob.agent_runner = lambda do |workspace_path:, env:, **_|
        credentials_path = File.join(home, ".syrus", "credentials")
        expect(File).not_to exist(credentials_path)

        cli_env = env.merge(
          "HOME" => home,
          "PATH" => ENV.fetch("PATH"),
          "TERM" => "dumb"
        )
        stdout, stderr, status = Open3.capture3(
          cli_env,
          cli_binary.to_s,
          "job", "show", job.id.to_s, "--json",
          chdir: workspace_path.to_s
        )

        expect(status).to be_success, stderr.presence || stdout
        expect(File).not_to exist(credentials_path)

        captured = JSON.parse(stdout)
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

      AgentProviders.for("claude").new(run: run, workspace: workspace, parent_session_id: nil)
        .run(prompt: "exercise the runtime CLI", log_sink: ->(_) {})
    ensure
      RunJob.agent_runner = nil
    end

    expect(captured.dig("job", "id")).to eq(job.id)
    expect(captured.dig("job", "title")).to eq("Runtime CLI smoke")
    expect(captured.dig("repository", "slug")).to eq("acme/widgets")
  end

  def workspace
    Struct.new(:path).new(workspace_path)
  end

  def cli_binary
    built = Rails.root.join("tmp/syrus-cli-smoke")
    return built if built.exist?

    FileUtils.mkdir_p(built.dirname)
    go = go_command
    _stdout, stderr, status = Open3.capture3(
      *go,
      "build", "-o", built.to_s, ".",
      chdir: Rails.root.join("cli").to_s
    )
    raise "failed to build Syrus CLI for smoke spec: #{stderr}" unless status.success?

    built
  end

  def go_command
    if system("mise", "--version", out: File::NULL, err: File::NULL)
      [ "mise", "exec", "go@1.26.5", "--", "go" ]
    else
      [ "go" ]
    end
  end

  def around_env(values)
    old = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def without_vcr
    VCR.turn_off!(ignore_cassettes: true)
    yield
  ensure
    VCR.turn_on!
  end

  def cleanup_records
    Job.where(id: @job.id).destroy_all if defined?(@job) && @job&.persisted?
    Repository.where(id: @repository.id).destroy_all if defined?(@repository) && @repository&.persisted?
    User.where(id: @user.id).destroy_all if defined?(@user) && @user&.persisted?
  end
end
