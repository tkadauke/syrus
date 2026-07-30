require "rails_helper"
require "tmpdir"

RSpec.describe "Steps::Grader :test_result_parser plugin integration" do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }

  after { Syrus::PluginRegistry.reset! }

  def make_step(junit_output: "output/results.json")
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 99,
      details: {
        "name" => "go-tests",
        "command" => "true",
        "required" => true,
        "timeout_minutes" => 1,
        "junit_output" => junit_output
      }
    )
  end

  around do |example|
    Dir.mktmpdir("syrus-grader-plugin") do |dir|
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

  def stub_parsed_run(total: 3, passed: 2, failed: 1, skipped: 0, errors: 0)
    case_double = double(
      name: "TestFoo", suite_name: "go_pkg", file_path: nil,
      status: "failed", duration_ms: 42,
      output: nil, failure_message: "assertion failed", failure_backtrace: nil
    )
    double(
      total_count: total, passed_count: passed, failed_count: failed,
      skipped_count: skipped, error_count: errors,
      duration_ms: 150,
      cases: [ case_double ]
    )
  end

  context "when a plugin parser matches" do
    it "uses the plugin parser's output instead of JUnit XML" do
      parsed = stub_parsed_run
      plugin = double("test_result_parser")
      output_path = @ws_path.join("output/results.json")
      FileUtils.mkdir_p(output_path.dirname)
      output_path.write('{"test":"data"}')

      allow(plugin).to receive(:can_parse?).with(output_path: output_path).and_return(true)
      allow(plugin).to receive(:call).with(output_path: output_path).and_return(parsed)
      Syrus::PluginRegistry.register(:test_result_parser, plugin)

      step = make_step
      handler, run = handler_for(step)

      expect { handler.call rescue nil }
        .to change(TestRun, :count).by(1)
        .and change(TestCase, :count).by(1)

      tr = TestRun.find_by!(run: run, grader_name: "go-tests")
      expect(tr).to have_attributes(
        total_count: 3,
        passed_count: 2,
        failed_count: 1
      )
    end

    it "does not attempt JUnit XML parsing when a plugin matches" do
      parsed = stub_parsed_run
      plugin = double("test_result_parser")
      output_path = @ws_path.join("output/results.json")
      FileUtils.mkdir_p(output_path.dirname)
      output_path.write("not xml at all")

      allow(plugin).to receive(:can_parse?).with(output_path: output_path).and_return(true)
      allow(plugin).to receive(:call).with(output_path: output_path).and_return(parsed)
      Syrus::PluginRegistry.register(:test_result_parser, plugin)

      step = make_step
      handler, run = handler_for(step)

      expect(JunitXmlParser).not_to receive(:parse)
      expect { handler.call rescue nil }.not_to raise_error
    end
  end

  context "when a plugin's can_parse? returns false" do
    it "falls through to JUnit XML parsing" do
      plugin = double("test_result_parser")
      output_path = @ws_path.join("output/results.json")
      FileUtils.mkdir_p(output_path.dirname)

      junit_xml = <<~XML
        <testsuite name="Suite" tests="1">
          <testcase classname="Suite" name="passes" time="0.1"/>
        </testsuite>
      XML
      output_path.write(junit_xml)

      allow(plugin).to receive(:can_parse?).with(output_path: output_path).and_return(false)
      expect(plugin).not_to receive(:call)
      Syrus::PluginRegistry.register(:test_result_parser, plugin)

      step = make_step
      handler, run = handler_for(step)

      expect { handler.call }.to change(TestRun, :count).by(1)
      expect(TestRun.find_by!(run: run, grader_name: "go-tests").total_count).to eq(1)
    end
  end

  context "when multiple plugins are registered" do
    it "uses the first matching plugin and skips the rest" do
      parsed = stub_parsed_run(total: 5, passed: 5, failed: 0)

      plugin_a = double("parser_a")
      plugin_b = double("parser_b")

      output_path = @ws_path.join("output/results.json")
      FileUtils.mkdir_p(output_path.dirname)
      output_path.write("{}")

      allow(plugin_a).to receive(:can_parse?).with(output_path: output_path).and_return(false)
      allow(plugin_b).to receive(:can_parse?).with(output_path: output_path).and_return(true)
      allow(plugin_b).to receive(:call).with(output_path: output_path).and_return(parsed)
      expect(plugin_a).not_to receive(:call)

      Syrus::PluginRegistry.register(:test_result_parser, plugin_a)
      Syrus::PluginRegistry.register(:test_result_parser, plugin_b)

      step = make_step
      handler, run = handler_for(step)

      expect { handler.call rescue nil }.to change(TestRun, :count).by(1)
      expect(TestRun.find_by!(run: run, grader_name: "go-tests").total_count).to eq(5)
    end
  end

  context "when no plugins are registered" do
    it "falls back to JUnit XML parsing" do
      output_path = @ws_path.join("output/results.json")
      FileUtils.mkdir_p(output_path.dirname)

      junit_xml = <<~XML
        <testsuite name="Suite" tests="2">
          <testcase classname="Suite" name="a" time="0.1"/>
          <testcase classname="Suite" name="b" time="0.2"/>
        </testsuite>
      XML
      output_path.write(junit_xml)

      step = make_step
      handler, run = handler_for(step)

      expect { handler.call }.to change(TestRun, :count).by(1)
      expect(TestRun.find_by!(run: run, grader_name: "go-tests").total_count).to eq(2)
    end
  end
end
