require "rails_helper"
require "tmpdir"

RSpec.describe "Steps::Grader JUnit XML ingestion" do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }

  def make_step(junit_output: nil)
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 99,
      details: {
        "name" => "tests",
        "command" => "true",
        "required" => true,
        "timeout_minutes" => 1,
        "junit_output" => junit_output
      }.compact
    )
  end

  around do |example|
    Dir.mktmpdir("syrus-grader-junit") do |dir|
      @ws_path = Pathname.new(dir)
      example.run
    end
  end

  def handler_for(step)
    run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running", iteration: step.iteration)
    h = Steps::Grader.new(run)
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(h).to receive(:workspace).and_return(fake_ws)
    [ h, run ]
  end

  let(:passing_xml) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <testsuite name="MySpec" tests="2" time="0.3">
        <testcase classname="MySpec" name="passes" time="0.2"/>
        <testcase classname="MySpec" name="is skipped" time="0.1">
          <skipped/>
        </testcase>
      </testsuite>
    XML
  end

  let(:failing_xml) do
    <<~XML
      <testsuite name="MySpec" tests="2" time="0.5">
        <testcase classname="MySpec" name="passes" time="0.2"/>
        <testcase classname="MySpec" name="fails" time="0.3">
          <failure message="assertion failed">line 10 in spec/my_spec.rb</failure>
        </testcase>
      </testsuite>
    XML
  end

  context "when junit_output is configured and file exists" do
    it "creates a TestRun and TestCase records" do
      step = make_step(junit_output: "tmp/results.xml")
      @ws_path.join("tmp").mkpath
      @ws_path.join("tmp/results.xml").write(passing_xml)

      handler, run = handler_for(step)
      expect { handler.call }.to change(TestRun, :count).by(1)
                              .and change(TestCase, :count).by(2)

      tr = TestRun.find_by!(run: run, grader_name: "tests")
      expect(tr).to have_attributes(
        total_count: 2,
        passed_count: 1,
        skipped_count: 1,
        failed_count: 0,
        error_count: 0,
        duration_ms: 300
      )
      expect(tr.repository).to eq(job.repository)
    end

    it "stores test case details correctly" do
      step = make_step(junit_output: "tmp/results.xml")
      @ws_path.join("tmp").mkpath
      @ws_path.join("tmp/results.xml").write(failing_xml)

      handler, run = handler_for(step)
      handler.call rescue nil

      tr = TestRun.find_by!(run: run, grader_name: "tests")
      failing_case = tr.test_cases.find_by!(name: "fails")
      expect(failing_case).to have_attributes(
        suite_name: "MySpec",
        status: "failed",
        failure_message: "assertion failed",
        failure_backtrace: "line 10 in spec/my_spec.rb",
        duration_ms: 300
      )
    end

    it "is idempotent: replaces an existing TestRun for the same run+grader_name" do
      step = make_step(junit_output: "results.xml")
      @ws_path.join("results.xml").write(passing_xml)

      handler, run = handler_for(step)
      handler.call

      step2 = make_step(junit_output: "results.xml")
      @ws_path.join("results.xml").write(failing_xml)
      run2 = step2.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running")
      h2 = Steps::Grader.new(run2)
      fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
      allow(h2).to receive(:workspace).and_return(fake_ws)

      expect { h2.call rescue nil }
        .to change { TestRun.where(run: run2, grader_name: "tests").count }.from(0).to(1)

      expect(TestRun.where(run: run, grader_name: "tests").count).to eq(1)
    end
  end

  context "when junit_output is not configured" do
    it "does not create any TestRun records" do
      step = make_step
      handler, = handler_for(step)
      expect { handler.call }.not_to change(TestRun, :count)
    end
  end

  context "when junit_output file does not exist" do
    it "logs a warning and does not fail the step" do
      step = make_step(junit_output: "missing/results.xml")
      handler, run = handler_for(step)

      expect { handler.call }.not_to raise_error
      expect(TestRun.where(run: run).count).to eq(0)

      log_output = run.reload.job_logs.pluck(:chunk).join
      expect(log_output).to include("not found")
    end
  end

  context "when the JUnit XML file is malformed" do
    it "logs a warning and does not fail the step" do
      step = make_step(junit_output: "results.xml")
      @ws_path.join("results.xml").write("<not valid xml")
      handler, run = handler_for(step)

      expect { handler.call }.not_to raise_error
      expect(TestRun.where(run: run).count).to eq(0)

      log_output = run.reload.job_logs.pluck(:chunk).join
      expect(log_output).to include("JUnit XML parse error")
    end
  end
end
