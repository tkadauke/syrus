require "rails_helper"
require "tmpdir"

RSpec.describe Steps::Grade do
  let(:job)      { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.first.tap { |s| s.update!(kind: "grade") } }
  let(:run)      { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler)  { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-grade") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
  end

  it "succeeds with a logged note when no graders are configured" do
    handler.call

    expect(workflow.reload.artifact("iterations")).to be_nil
    expect(run.reload.job_logs.pluck(:chunk).join("\n")).to include("no graders configured")
  end

  it "runs all graders, writes log files, and records passing artifacts" do
    write_config <<~YAML
      grade:
        steps:
          - name: tests
            run: ruby -e 'puts "ok"; warn "also ok"'
          - name: lint
            run: ruby -e 'puts "lint ok"'
    YAML

    handler.call

    entries = artifact_entries
    expect(entries.map { |entry| entry["name"] }).to eq(%w[tests lint])
    expect(entries.map { |entry| entry["status"] }).to eq(%w[passed passed])
    expect(entries.all? { |entry| entry["required"] }).to be(true)
    expect(entries.all? { |entry| entry["log_bytes"].positive? }).to be(true)

    tests_log = @ws_path.join(entries.first["log_path"])
    expect(tests_log.read).to include("ok")
    expect(tests_log.read).to include("also ok")
    expect(entries.first["log_bytes"]).to eq(tests_log.size)
  end

  it "fails fast after a required grader failure and records the rest as skipped" do
    write_config <<~YAML
      grade:
        steps:
          - name: tests
            run: ruby -e 'warn "boom"; exit 7'
          - name: lint
            run: ruby -e 'puts "should not run"'
    YAML

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /required grader failed/)

    entries = artifact_entries
    expect(entries.map { |entry| entry["status"] }).to eq(%w[failed skipped])
    expect(entries.first["exit_code"]).to eq(7)
    expect(entries.first["output"]).to include("boom")
    expect(entries.last["reason"]).to eq("earlier required grader failed")
    expect(@ws_path.join(entries.last["log_path"]).read).to include("[skipped: earlier required grader failed]")
  end

  it "allows advisory grader failures when required graders pass" do
    write_config <<~YAML
      grade:
        steps:
          - name: audit
            required: false
            run: ruby -e 'exit 9'
          - name: tests
            run: ruby -e 'puts "required ok"'
    YAML

    expect { handler.call }.not_to raise_error

    entries = artifact_entries
    expect(entries.map { |entry| [ entry["name"], entry["required"], entry["status"], entry["exit_code"] ] }).to eq([
      [ "audit", false, "failed", 9 ],
      [ "tests", true, "passed", 0 ]
    ])
  end

  it "records timeout failures with exit 124 and a timeout marker" do
    write_config <<~YAML
      grade:
        steps:
          - name: tests
            run: ruby -e 'sleep 10'
            timeout_minutes: 15
    YAML
    fake_runner = instance_double(ProcessRunner)
    allow(ProcessRunner).to receive(:new).and_return(fake_runner)
    allow(fake_runner).to receive(:run).and_return(
      ProcessRunner::Result.new(exit_status: nil, timed_out: true, stopped: false, silent_timed_out: false, operator_killed: false, aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil)
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed)

    entry = artifact_entries.first
    expect(entry["status"]).to eq("failed")
    expect(entry["exit_code"]).to eq(124)
    expect(@ws_path.join(entry["log_path"]).read).to include("[timed out after 15 minutes]")
    expect(entry["log_bytes"]).to eq(@ws_path.join(entry["log_path"]).size)
  end

  it "scrubs the environment using the prepare allowlist" do
    write_config <<~YAML
      grade:
        - name: envcheck
          run: ruby -e 'abort "leaked" if ENV["BUNDLE_WITHOUT"]'
    YAML

    old_value = ENV["BUNDLE_WITHOUT"]
    ENV["BUNDLE_WITHOUT"] = "development:test"
    handler.call

    expect(artifact_entries.first["status"]).to eq("passed")
  ensure
    ENV["BUNDLE_WITHOUT"] = old_value
  end

  it "appends results to the current run iteration slot" do
    run.update!(iteration: 2)
    workflow.set_artifact!("iterations", [ [ { "name" => "previous", "status" => "failed" } ] ])
    write_config <<~YAML
      grade:
        steps:
          - name: tests
            run: ruby -e 'exit 0'
    YAML

    handler.call

    iterations = workflow.reload.artifact("iterations")
    expect(iterations[0].first["name"]).to eq("previous")
    expect(iterations[1].first["name"]).to eq("tests")
  end

  it "persists multi-iteration grader artifacts larger than MySQL TEXT" do
    output = "x" * (15 * 1024)
    iterations = 5.times.map do |iteration|
      4.times.map do |grader|
        {
          "name" => "grader-#{iteration}-#{grader}",
          "required" => true,
          "status" => "failed",
          "exit_code" => 1,
          "duration_s" => 1.0,
          "log_path" => ".syrus/grade-output/iteration-#{iteration + 1}/grader-#{grader}.log",
          "log_bytes" => output.bytesize,
          "output" => output
        }
      end
    end
    artifacts = { "iterations" => iterations }
    artifact_bytes = JSON.dump(artifacts).bytesize

    expect(artifact_bytes).to be > 65_535
    expect(Workflow.columns_hash.fetch("artifacts").limit).to be >= artifact_bytes
    expect { workflow.update!(artifacts: artifacts) }.not_to raise_error
    expect(workflow.reload.artifact("iterations").size).to eq(5)
  end

  def write_config(contents)
    File.write(@ws_path.join(".syrus.yml"), contents)
  end

  def artifact_entries
    workflow.reload.artifact("iterations").fetch(run.iteration - 1)
  end
end
