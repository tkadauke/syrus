require "rails_helper"
require "tmpdir"

RSpec.describe CaptureRunDiagnostic, :ci_only do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:job)  { Factories.job(repository: repo) }
  let(:run)  { job.initial_run }
  let(:exception) do
    err = RuntimeError.new("orphan branch nuked the run")
    err.set_backtrace([ "/app/jobs/run_job.rb:172:in `capture_diff_against_default'" ])
    err
  end

  it "creates a RunDiagnostic with exception details" do
    expect {
      described_class.capture(run, exception, workspace: nil)
    }.to change { RunDiagnostic.count }.by(1)

    diag = run.reload.run_diagnostic
    expect(diag.error_class).to eq("RuntimeError")
    expect(diag.error_message).to include("orphan branch nuked")
    expect(diag.error_backtrace).to include("run_job.rb")
    expect(diag.git_snapshot).to include("note" => /no workspace/)
  end

  it "is idempotent — won't overwrite an existing diagnostic for the same Run" do
    described_class.capture(run, exception)
    expect {
      described_class.capture(run, RuntimeError.new("different error"))
    }.not_to change { RunDiagnostic.count }
  end

  it "swallows its own errors instead of double-faulting the failing rescue path" do
    allow(RunDiagnostic).to receive(:create!).and_raise(StandardError, "oops")
    expect {
      described_class.capture(run, exception)
    }.not_to raise_error
  end

  describe "git snapshot" do
    let(:worktree_path) { Pathname.new(Dir.mktmpdir("diag-spec-wt")) }
    after { FileUtils.rm_rf(worktree_path) }

    let(:workspace) { Struct.new(:path).new(worktree_path) }

    before do
      sh("git init -q -b main #{worktree_path}")
      sh("git -C #{worktree_path} -c user.name=t -c user.email=t@e commit -q --allow-empty -m 'seed'")
    end

    it "captures git status / log / branches when a workspace is given" do
      File.write(worktree_path.join("dirty.rb"), "junk")
      described_class.capture(run, exception, workspace: workspace)
      snap = run.reload.run_diagnostic.git_snapshot
      expect(snap["head"]).to match(/\A[0-9a-f]{40}\n?\z/)
      expect(snap["status"]).to include("dirty.rb")
      expect(snap["log_recent"]).to include("seed")
    end

    it "doesn't raise when individual git commands fail — captures the error in the snapshot value" do
      # Make merge-base fail by pointing at a base branch that doesn't exist.
      allow(repo).to receive(:default_branch).and_return("ghost-branch")
      described_class.capture(run, exception, workspace: workspace)
      snap = run.reload.run_diagnostic.git_snapshot
      expect(snap["merge_base_main"]).to start_with("(GitRunner::GitError")
    end
  end

  describe "environment snapshot" do
    around do |ex|
      ENV["RAILS_ENV"]              = "production"
      ENV["SYRUS_DATABASE_PASSWORD"] = "shhh-very-secret"
      ENV["KUBERNETES_SERVICE_HOST"] = "10.0.0.1"
      ENV["RANDOM_VAR"]              = "ignored"
      ex.run
    ensure
      %w[RAILS_ENV SYRUS_DATABASE_PASSWORD KUBERNETES_SERVICE_HOST RANDOM_VAR].each { |k| ENV.delete(k) }
    end

    it "allowlists Rails/k8s/Syrus vars and drops everything else (incl. anything secret-looking)" do
      described_class.capture(run, exception)
      env = run.reload.run_diagnostic.environment_snapshot
      expect(env["RAILS_ENV"]).to eq("production")
      expect(env["KUBERNETES_SERVICE_HOST"]).to eq("10.0.0.1")
      expect(env).not_to have_key("SYRUS_DATABASE_PASSWORD")
      expect(env).not_to have_key("RANDOM_VAR")
    end

    it "stamps ruby + rails + git versions" do
      described_class.capture(run, exception)
      env = run.reload.run_diagnostic.environment_snapshot
      expect(env["ruby_version"]).to eq(RUBY_VERSION)
      expect(env["rails_version"]).to eq(Rails.version)
      expect(env["git_version"]).to match(/git version/)
    end
  end

  describe "repo snapshot" do
    it "carries job + repo metadata" do
      job.update!(branch_name: "syrus/issue-7-#{job.id}")
      described_class.capture(run, exception)
      snap = run.reload.run_diagnostic.repo_snapshot
      expect(snap["repository_slug"]).to eq(job.repository.slug)
      expect(snap["job_branch"]).to eq("syrus/issue-7-#{job.id}")
      expect(snap["run_trigger_kind"]).to eq("initial")
    end

    it "includes bounded command span timing for failed run diagnostics" do
      run.command_spans.create!(
        job: job,
        workflow: run.workflow,
        step: run.step,
        sequence: 1,
        name: "rspec",
        command_excerpt: "bin/rspec",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago,
        duration_ms: 60_000,
        exit_status: 1,
        outcome: "failed",
        hostname: "worker-a"
      )

      described_class.capture(run, exception)

      span = run.reload.run_diagnostic.repo_snapshot.fetch("command_spans").first
      expect(span).to include(
        "name" => "rspec",
        "command_excerpt" => "bin/rspec",
        "duration_ms" => 60_000,
        "outcome" => "failed",
        "hostname" => "worker-a"
      )
    end
  end

  def sh(cmd)
    out, err, status = Open3.capture3(cmd)
    raise "shell failed: #{cmd}\n#{out}\n#{err}" unless status.success?
    out
  end
end
