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

  it "redacts compound secret assignments from recorded commands" do
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      failed_cases: failed_cases,
      log: ->(_message) { }
    )

    command = "SECRET_KEY_BASE=one AWS_SECRET_ACCESS_KEY=two PRIVATE_KEY=three bin/rspec-fast"

    expect(retry_check.send(:redacted_command, command)).to eq(
      "SECRET_KEY_BASE=[REDACTED] AWS_SECRET_ACCESS_KEY=[REDACTED] PRIVATE_KEY=[REDACTED] bin/rspec-fast"
    )
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

  # A focused retry that never finishes used to be reported as
  # base_retry_output_not_parseable, which names a grader-configuration problem
  # and sent the diagnosis in the wrong direction: the retry installs
  # dependencies, prepares a database and runs the failed files in a bare base
  # worktree, so the thing most likely to go wrong is that it runs out of time.
  it "reports a focused retry that never finishes as a timeout, not as unparseable output" do
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
    # What run_command returns when it kills the command at TIMEOUT_SECONDS,
    # which it is covered for separately.
    allow(retry_check).to receive(:run_command) do |_command, _chdir, output|
      output << "some output\n[brr] timed out after 600s\n"
      nil
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: false,
      inherited: false,
      reason: "base_retry_focused_command_timed_out",
      command: "bin/rspec-fast spec/models/widget_spec.rb"
    )
    expect(result.output).to include("[brr] timed out")
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

  it "kills a hung base command when the timeout expires" do
    stub_const("#{described_class}::TIMEOUT_SECONDS", 1)
    child_pid_path = @workspace_path.join("child.pid")
    grader_step.update!(details: grader_step.details.merge(
      "command" => "printf 'started\\n'; sleep 5 & child=$!; printf '%s' \"$child\" > #{Shellwords.escape(child_pid_path.to_s)}; wait \"$child\"",
      "base_retry" => { "strategy" => "full_command" }
    ))
    grader_run = Run.create!(
      job: job,
      step: grader_step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      state: "failed"
    )
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      failed_cases: failed_cases,
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:git) do |*args|
      FileUtils.mkdir_p(args.fetch(3)) if args.first(3) == [ "worktree", "add", "--detach" ]
      ""
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = nil
    expect do
      result = retry_check.call
    end.to change(SpawnedProcess, :count).by(1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    expect(result).to have_attributes(ran: false, reason: "base_retry_full_command_timed_out")
    expect(elapsed).to be < 2.5
    expect(SpawnedProcess.order(:id).last).to have_attributes(
      kind: "grader",
      run: grader_run,
      workflow: workflow,
      outcome: "timed_out"
    )
    child_pid = child_pid_path.read.to_i
    child_active = begin
      File.read("/proc/#{child_pid}/stat").split.fetch(2) != "Z"
    rescue Errno::ENOENT
      false
    end
    expect(child_active).to be(false)
  end

  # Regression. A focused retry runs `bin/rspec-worker` directly instead of the
  # grader's full command, so it never writes the merged junit file the grader
  # step advertises -- rspec-worker writes one per-worker file under
  # .syrus/rspec-junit/. Searching only .syrus/grade-output/ found nothing and
  # fell through to parsing progress-formatter dots, which carry no per-case
  # results, so every rspec base retry reported
  # `base_retry_output_not_parseable`. With no base comparison the grader could
  # never apply `allow_inherited`, and the main branch stayed red.
  it "finds the junit that a focused rspec-worker retry actually writes" do
    worker_step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 2,
      state: "failed",
      details: {
        "name" => "rspec-ci",
        "command" => "bundle exec parallel_rspec --exec-args bin/rspec-worker",
        # Written by the grader's own merge pass, never by a focused retry.
        "junit_output" => ".syrus/grade-output/rspec-ci-junit.xml",
        "base_retry" => { "strategy" => "plugin" }
      }
    )
    provider = Class.new do
      def self.command_for(**)
        "bin/rspec-worker spec/models/widget_spec.rb"
      end
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:focused_test_command).and_return([ provider ])
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: worker_step,
      base_sha: "main123",
      failed_cases: failed_cases,
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |_command, chdir, output|
      path = chdir.join(".syrus/rspec-junit/rspec-junit-_syrus_flaky_abc12345.xml")
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
      reason: "base_retry_failed_cases_match"
    )
  end
end
