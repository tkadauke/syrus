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
      log: ->(_message) {}
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
      log: ->(_message) {}
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
      log: ->(_message) {}
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
end
