require "rails_helper"
require "tmpdir"

RSpec.describe BaseRevisionRetry do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:grader_step) do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 1,
      state: "failed",
      details: {
        "name" => "rspec",
        "command" => "bin/rspec-fast",
        "junit_output" => ".syrus/grade-output/rspec-junit.xml",
        "base_retry" => { "strategy" => "plugin" }
      }
    )
  end
  let(:failed_cases) do
    [
      {
        "suite_name" => "spec/models/widget_spec.rb",
        "name" => "Widget fails",
        "file_path" => "spec/models/widget_spec.rb",
        "identity" => "spec/models/widget_spec.rb\0Widget fails"
      }
    ]
  end

  around do |example|
    Dir.mktmpdir("syrus-brr-spec-workspace") do |dir|
      @workspace_path = Pathname.new(dir)
      example.run
    end
  end

  before do
    allow(StepWorkspace).to receive(:for).and_return(double(path: @workspace_path))
    allow(GitRunner).to receive(:new).and_return(instance_double(GitRunner, run: ""))
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with("test_insights:parser").and_return([])
  end

  it "treats failed tests as inherited when the focused base run reports the same failures" do
    provider = Class.new do
      def self.command_for(**)
        "bin/rspec-fast spec/models/widget_spec.rb"
      end
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:focused_test_command).and_return([ provider ])
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      failed_cases: failed_cases,
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |_command, chdir, output|
      path = chdir.join(".syrus/grade-output/rspec-junit.xml")
      FileUtils.mkdir_p(path.dirname)
      path.write(<<~XML)
        <testsuite name="spec/models/widget_spec.rb">
          <testcase classname="spec/models/widget_spec.rb" name="Widget fails">
            <failure message="same failure">same failure</failure>
          </testcase>
        </testsuite>
      XML
      output << "1 example, 1 failure"
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: true,
      reason: "base_retry_failed_cases_match",
      command: "bin/rspec-fast spec/models/widget_spec.rb"
    )
    expect(result.base_failed_identities).to eq([ "spec/models/widget_spec.rb\0Widget fails" ])
  end

  it "keeps the failure when the focused base run does not report the candidate failure" do
    provider = Class.new do
      def self.command_for(**)
        "bin/rspec-fast spec/models/widget_spec.rb"
      end
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:focused_test_command).and_return([ provider ])
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      failed_cases: failed_cases,
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |_command, chdir, output|
      path = chdir.join(".syrus/grade-output/rspec-junit.xml")
      FileUtils.mkdir_p(path.dirname)
      path.write(<<~XML)
        <testsuite name="spec/models/widget_spec.rb">
          <testcase classname="spec/models/widget_spec.rb" name="Widget fails" />
        </testsuite>
      XML
      output << "1 example, 0 failures"
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: false,
      reason: "base_retry_found_introduced_cases"
    )
    expect(result.introduced_failed_identities).to eq([ "spec/models/widget_spec.rb\0Widget fails" ])
  end

  it "appends failed test files when configured for files_as_args" do
    grader_step.update!(details: grader_step.details.merge("base_retry" => { "strategy" => "files_as_args" }))
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      failed_cases: failed_cases,
      log: ->(_message) { }
    )
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:focused_test_command).and_return([])
    allow(retry_check).to receive(:run_command) do |_command, chdir, _output|
      path = chdir.join(".syrus/grade-output/rspec-junit.xml")
      FileUtils.mkdir_p(path.dirname)
      path.write(<<~XML)
        <testsuite name="spec/models/widget_spec.rb">
          <testcase classname="spec/models/widget_spec.rb" name="Widget fails">
            <failure message="same failure">same failure</failure>
          </testcase>
        </testsuite>
      XML
    end

    result = retry_check.call

    expect(result.command).to eq("bin/rspec-fast spec/models/widget_spec.rb")
  end

  it "falls back to the full grader command when files_as_args has no failed cases" do
    grader_step.update!(
      details: grader_step.details.merge(
        "output" => "Vitest failed before structured cases were stored\n",
        "base_retry" => { "strategy" => "files_as_args" }
      )
    )
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      failed_cases: [],
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |_command, _chdir, output|
      output << "Vitest failed before structured cases were stored\n"
      instance_double(Process::Status, success?: false)
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: true,
      reason: "base_retry_full_command_failed_same_output",
      command: "bin/rspec-fast"
    )
  end

  it "falls back to the full grader command when files_as_args cannot synthesize a focused command" do
    grader_step.update!(details: grader_step.details.merge("base_retry" => { "strategy" => "files_as_args" }))
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      failed_cases: failed_cases.map { |test_case| test_case.except("file_path") },
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |_command, _chdir, output|
      output << "Base passed\n"
      instance_double(Process::Status, success?: true)
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: false,
      reason: "base_retry_full_command_base_passed",
      command: "bin/rspec-fast"
    )
  end

  it "treats non-test graders as inherited when the full base command fails with the same output" do
    grader_step.update!(
      details: {
        "name" => "website-build",
        "command" => "npm run website-build",
        "output" => "Build failed: missing generated plugin data\n",
        "base_retry" => { "strategy" => "full_command" }
      }
    )
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |_command, _chdir, output|
      output << "Build failed: missing generated plugin data\n"
      instance_double(Process::Status, success?: false)
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: true,
      reason: "base_retry_full_command_failed_same_output",
      command: "npm run website-build"
    )
  end

  it "treats non-test graders as inherited when the full base command fails with different (flaky) output" do
    grader_step.update!(
      details: {
        "name" => "work-engine-simulations",
        "command" => "bin/simulator",
        "output" => "1 scenario stuck: reason A\n",
        "base_retry" => { "strategy" => "full_command" }
      }
    )
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |_command, _chdir, output|
      output << "1 scenario stuck: reason B\n"
      instance_double(Process::Status, success?: false)
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: true,
      reason: "base_retry_full_command_failed_different_output",
      command: "bin/simulator"
    )
  end

  it "keeps non-test grader failures when the full base command passes" do
    grader_step.update!(
      details: {
        "name" => "website-build",
        "command" => "npm run website-build",
        "output" => "Build failed: missing generated plugin data\n",
        "base_retry" => { "strategy" => "full_command" }
      }
    )
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |_command, _chdir, output|
      output << "Build succeeded\n"
      instance_double(Process::Status, success?: true)
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: false,
      reason: "base_retry_full_command_base_passed"
    )
  end
end
