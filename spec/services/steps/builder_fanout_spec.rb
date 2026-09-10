require "rails_helper"
require "tmpdir"

RSpec.describe Steps::BuilderFanout do
  let(:job) { Factories.job_record }
  let(:workflow) do
    Workflow.create!(
      job: job,
      user: job.user,
      trigger_kind: "main_grader",
      agent_provider: job.agent_provider,
      priority: job.priority,
      artifacts: { "main_sha" => "abc123", "previous_main_sha" => "old123" }
    )
  end
  let(:step) { Step.create!(workflow: workflow, kind: "builder_fanout", position: 1) }
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running") }
  let(:handler) { described_class.new(run) }

  let(:success_result) do
    ProcessRunner::Result.new(
      exit_status: 0, timed_out: false, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
    )
  end
  let(:failure_result) do
    ProcessRunner::Result.new(
      exit_status: 1, timed_out: false, stopped: false,
      silent_timed_out: false, operator_killed: false,
      aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
    )
  end

  around do |ex|
    Dir.mktmpdir("syrus-builder-fanout") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)

    git = instance_double(GitRunner)
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: @ws_path.to_s).and_return("abc123\n")
    allow(git).to receive(:run).with("diff", "--name-only", "old123...HEAD", chdir: @ws_path.to_s).and_return("app/frontend/src/app.ts\n")
  end

  def write_config(contents)
    @ws_path.join(".syrus.yml").write(contents)
  end

  def write_file(path, contents = "")
    absolute = @ws_path.join(path)
    FileUtils.mkdir_p(absolute.dirname)
    absolute.write(contents)
  end

  def stub_runner(result = success_result)
    allow(ProcessRunner).to receive(:new) do |**args|
      args[:on_output_chunk].call("builder output\n")
      instance_double(ProcessRunner, run: result)
    end
  end

  def record_target_health(label, status: "passed")
    graph = TargetGraph::Compiler.compile(@ws_path)
    target = graph.target(TargetGraph::Label.parse(label))
    fingerprints = TargetGraph::Fingerprints.for_target(
      workspace_path: @ws_path,
      graph: graph,
      label: target.label
    )
    TargetHealthRecorder.record!(
      repository: job.repository,
      target_label: target.label.to_s,
      project_id: target.project_id,
      commit_sha: "previous456",
      input_fingerprint: fingerprints.input_fingerprint,
      command_fingerprint: fingerprints.command_fingerprint,
      environment_fingerprint: fingerprints.environment_fingerprint,
      status: status
    )
  end

  it "builds hot affected builder targets and records reusable target health with artifacts" do
    write_file("app/frontend/src/app.ts", "console.log('hi')\n")
    write_file("dist/app.js", "compiled\n")
    write_config(<<~YAML)
      targets:
        - name: assets
          kind: builder
          run: npm run build
          sources: ["app/frontend/**/*"]
          cost: expensive
          artifacts: ["dist/**/*"]
    YAML
    stub_runner

    handler.call

    record = TargetHealthRecord.where(repository: job.repository, target_label: "//:assets").sole
    expect(record).to have_attributes(
      project_id: "repo",
      commit_sha: "abc123",
      status: "passed",
      exit_code: 0
    )
    expect(record.artifacts).to include(
      "declared_paths" => [ "dist/**/*" ],
      "existing_paths" => [ include("path" => "dist/app.js", "bytes" => 9) ]
    )
    expect(workflow.reload.artifact(described_class::ARTIFACT_KEY)).to include(
      include("target_label" => "//:assets", "status" => "passed")
    )
  end

  it "does not build cheap low-value builder targets by default" do
    write_file("app/frontend/src/app.ts", "console.log('hi')\n")
    write_config(<<~YAML)
      targets:
        - name: assets
          kind: builder
          run: npm run build
          sources: ["app/frontend/**/*"]
          cost: cheap
    YAML

    expect(ProcessRunner).not_to receive(:new)

    handler.call

    expect(TargetHealthRecord.where(repository: job.repository)).to be_empty
    expect(workflow.reload.artifact(described_class::ARTIFACT_KEY)).to eq([])
  end

  it "records failed target health without failing the builder fanout step" do
    write_file("app/frontend/src/app.ts", "console.log('hi')\n")
    write_config(<<~YAML)
      targets:
        - name: assets
          kind: builder
          run: npm run build
          sources: ["app/frontend/**/*"]
          hot: true
    YAML
    stub_runner(failure_result)

    expect { handler.call }.not_to raise_error

    record = TargetHealthRecord.where(repository: job.repository, target_label: "//:assets").sole
    expect(record).to have_attributes(status: "failed", exit_code: 1)
    expect(workflow.reload.artifact(described_class::ARTIFACT_KEY)).to include(
      include("target_label" => "//:assets", "status" => "failed")
    )
  end

  it "skips affected builders with reusable target health" do
    write_file("app/frontend/src/app.ts", "console.log('hi')\n")
    write_config(<<~YAML)
      targets:
        - name: assets
          kind: builder
          run: npm run build
          sources: ["app/frontend/**/*"]
          hot: true
    YAML
    existing = record_target_health("//:assets")

    expect(ProcessRunner).not_to receive(:new)

    handler.call

    entries = workflow.reload.artifact(described_class::ARTIFACT_KEY)
    expect(entries).to include(
      include(
        "target_label" => "//:assets",
        "status" => "skipped",
        "target_health_record_refs" => [ include("target_health_record_id" => existing.id) ]
      )
    )
  end
end
