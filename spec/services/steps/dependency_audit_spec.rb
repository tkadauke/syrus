require "rails_helper"
require "tmpdir"

RSpec.describe Steps::DependencyAudit do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.first.tap { |s| s.update!(kind: "dependency_audit") } }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  let(:success_result) do
    ProcessRunner::Result.new(
      exit_status: 0, timed_out: false, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
    )
  end

  let(:flagged_result) do
    ProcessRunner::Result.new(
      exit_status: 1, timed_out: false, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
    )
  end

  around do |ex|
    Dir.mktmpdir("syrus-dependency-audit") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path, base_ref: WorkflowWorkspace.base_ref_for(job))
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  after { Syrus::PluginRegistry.reset! }

  def stub_changed_files(*files)
    allow(GitRunner).to receive(:new).and_return(
      instance_double(GitRunner, run: files.join("\n"))
    )
  end

  def register_provider(lockfiles:, command:)
    provider = Class.new { include Syrus::Plugin::DependencyAuditCommand }
    provider.define_singleton_method(:lockfiles) { lockfiles }
    provider.define_singleton_method(:audit_command) { |workspace_path:| command }
    Syrus::PluginRegistry.register(:dependency_audit_command, provider)
    provider
  end

  it "no-ops when the diff has no changed files" do
    stub_changed_files
    expect { handler.call }.not_to raise_error

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("no changed files")
    expect(workflow.reload.artifact("dependency_audit")).to be_nil
  end

  it "no-ops when no changed file matches a registered provider's lockfiles" do
    stub_changed_files("app/models/user.rb", "README.md")
    register_provider(lockfiles: [ "Gemfile.lock" ], command: "bundle-audit check --update")

    expect { handler.call }.not_to raise_error

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("no changed lockfile matches")
    expect(workflow.reload.artifact("dependency_audit")).to be_nil
  end

  it "no-ops when the matching provider declines to return a command" do
    stub_changed_files("Gemfile.lock")
    provider = Class.new { include Syrus::Plugin::DependencyAuditCommand }
    provider.define_singleton_method(:lockfiles) { [ "Gemfile.lock" ] }
    provider.define_singleton_method(:audit_command) { |workspace_path:| nil }
    Syrus::PluginRegistry.register(:dependency_audit_command, provider)

    expect { handler.call }.not_to raise_error

    expect(workflow.reload.artifact("dependency_audit")).to be_nil
  end

  it "runs the matching provider's command and records a clean scan without a PR comment body" do
    stub_changed_files("Gemfile.lock")
    register_provider(lockfiles: [ "Gemfile.lock" ], command: "echo clean")

    handler.call

    artifact = workflow.reload.artifact("dependency_audit")
    expect(artifact["results"].size).to eq(1)
    result = artifact["results"].first
    expect(result["command"]).to eq("echo clean")
    expect(result["exit_status"]).to eq(0)
    expect(result["clean"]).to be(true)
    expect(artifact).not_to have_key("pr_comment_body")

    chunks = run.reload.job_logs.pluck(:chunk).join("\n")
    expect(chunks).to include("1 clean")
    expect(chunks).to include("0 flagged")
  end

  it "surfaces a flagged scan with a PR comment body" do
    stub_changed_files("Gemfile.lock")
    register_provider(lockfiles: [ "Gemfile.lock" ], command: "some-audit-tool")
    fake_runner = instance_double(ProcessRunner, run: flagged_result)
    allow(ProcessRunner).to receive(:new).and_return(fake_runner)

    handler.call

    artifact = workflow.reload.artifact("dependency_audit")
    result = artifact["results"].first
    expect(result["exit_status"]).to eq(1)
    expect(result["clean"]).to be(false)
    expect(artifact["pr_comment_body"]).to include(DependencyAuditReport::PrCommentFormatter::MARKER)
    expect(artifact["pr_comment_body"]).to include("some-audit-tool")
  end

  it "only runs providers whose lockfiles were actually changed, not every registered provider" do
    stub_changed_files("Gemfile.lock")
    register_provider(lockfiles: [ "Gemfile.lock" ], command: "echo ruby")
    register_provider(lockfiles: [ "go.sum" ], command: "echo go")

    handler.call

    artifact = workflow.reload.artifact("dependency_audit")
    expect(artifact["results"].size).to eq(1)
    expect(artifact["results"].first["command"]).to eq("echo ruby")
  end

  it "runs commands with workspace-local dependency env, mirroring Autofix" do
    stub_changed_files("Gemfile.lock")
    register_provider(lockfiles: [ "Gemfile.lock" ], command: "bundle-audit check --update")
    captured_env = nil
    fake_runner = instance_double(ProcessRunner, run: success_result)
    allow(ProcessRunner).to receive(:new) do |**kwargs|
      captured_env = kwargs.fetch(:env)
      fake_runner
    end

    handler.call

    deps = @ws_path.join(".syrus", "deps")
    expect(captured_env).to include(
      "BUNDLE_PATH"       => deps.join("bundle").to_s,
      "BUNDLE_APP_CONFIG" => deps.join("bundle-config").to_s
    )
  end
end
