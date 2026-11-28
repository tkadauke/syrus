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

  def command_execution(success: true, skip_reason: nil)
    described_class::CommandExecution.new(
      result: instance_double(Process::Status, success?: success),
      skip_reason: skip_reason
    )
  end

  def process_runner_result(timed_out: false, operator_killed: false, exit_status: nil)
    ProcessRunner::Result.new(
      exit_status: exit_status,
      timed_out: timed_out,
      stopped: false,
      silent_timed_out: false,
      operator_killed: operator_killed,
      aliveness_failed: false,
      duration_s: 0.1,
      spawned_process_id: nil
    )
  end

  around do |example|
    Dir.mktmpdir("syrus-brr-spec-workspace") do |dir|
      @workspace_path = Pathname.new(dir).join("immutable-checkouts/steps/1")
      FileUtils.mkdir_p(@workspace_path)
      example.run
    end
  end

  before do
    allow(StepWorkspace).to receive(:for).and_return(double(path: @workspace_path))
    allow(GitRunner).to receive(:new).and_return(instance_double(GitRunner, run: ""))
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with("test_insights:parser").and_return([])
  end

  def stub_focused_test_command(command)
    allow(Syrus::Plugin::Dispatch).to receive(:call).and_call_original
    allow(Syrus::Plugin::Dispatch).to receive(:call)
      .with(:ecosystem, :focused_tests, kind_of(Syrus::Plugin::Context::GraderContext))
      .and_return(command)
  end

  describe "base checkout materialization" do
    let(:git) { instance_double(GitRunner, run: "") }

    before do
      allow(GitRunner).to receive(:new).and_return(git)
      FileUtils.mkdir_p(@workspace_path.join("vendor/bundle/ruby/gem"))
      @workspace_path.join("vendor/bundle/ruby/gem/gem.rb").write("module Gem; end\n")
      FileUtils.mkdir_p(@workspace_path.join(".git"))
      @workspace_path.join(".git/HEAD").write("ref: refs/heads/main\n")
    end

    def retry_check
      provider = Class.new do
        def self.command_for(**)
          "bin/rspec-fast spec/models/widget_spec.rb"
        end
      end
      stub_focused_test_command(provider.command_for)
      described_class.new(
        workflow: workflow,
        grader_step: grader_step,
        base_sha: "main123",
        failed_cases: failed_cases,
        log: ->(_message) { }
      )
    end

    # The dependencies are what a bare worktree lacks, and what made the
    # focused command install the whole bundle inside its own timeout.
    it "links the prepared checkout so the base run already has its dependencies" do
      check = retry_check
      allow(check).to receive(:run_command) do |_command, chdir, output|
        expect(chdir.join("vendor/bundle/ruby/gem/gem.rb")).to exist
        output << "ran"
        nil
      end

      check.call

      expect(git).to have_received(:run).with("checkout", "--detach", "main123", hash_including(:chdir))
      expect(git).not_to have_received(:run).with("worktree", "add", any_args)
    end

    # Hard links cannot cross filesystems, and the system temp directory is a
    # different one from the workflow scratch volume on production workers.
    it "builds the base checkout beside the prepared checkout, on the same filesystem" do
      check = retry_check
      checkout = nil
      allow(check).to receive(:run_command) do |_command, chdir, output|
        checkout = chdir
        output << "ran"
        nil
      end

      check.call

      expect(checkout.to_s).to start_with("#{@workspace_path.dirname}/syrus-brr-")
      expect(checkout).not_to exist
    end

    it "falls back to a worktree when the prepared checkout cannot be linked" do
      allow(ImmutableSourceCheckoutLinkTree).to receive(:link).and_return(
        ImmutableSourceCheckoutLinkTree::Result.new(false, "hardlink materialization failed: Errno::EXDEV", [])
      )
      check = retry_check
      allow(check).to receive(:run_command) { |_command, _chdir, output| output << "ran" and nil }

      check.call

      expect(git).to have_received(:run).with("worktree", "add", "--detach", anything, "main123", any_args)
    end
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

  # Regression: a main grader's merge-base with main is its own HEAD, so its
  # "base" rerun re-ran the failing tests on the same commit, reproduced them,
  # and accepted every real failure on main as inherited.
  it "refuses to compare a candidate against itself" do
    head_sha = "50d35be2900000000000000000000000000000aa"
    git = instance_double(GitRunner)
    allow(git).to receive(:run) { |*args, **| args.first(2) == %w[rev-parse HEAD] ? "#{head_sha}\n" : "" }
    allow(GitRunner).to receive(:new).and_return(git)
    stub_focused_test_command("bin/rspec-fast spec/models/widget_spec.rb")
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: head_sha,
      failed_cases: failed_cases,
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command)

    result = retry_check.call

    expect(result).to have_attributes(ran: false, inherited: false, reason: "base_is_candidate_revision")
    expect(retry_check).not_to have_received(:run_command)
  end

  it "treats failed tests as inherited when the focused base run reports the same failures" do
    provider = Class.new do
      def self.command_for(**)
        "bin/rspec-fast spec/models/widget_spec.rb"
      end
    end
    allow(Syrus::Plugin::Dispatch).to receive(:call).and_call_original
    allow(Syrus::Plugin::Dispatch).to receive(:call)
      .with(:ecosystem, :focused_tests, kind_of(Syrus::Plugin::Context::GraderContext))
      .and_return("bin/rspec-fast spec/models/widget_spec.rb")
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
      command_execution
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

  it "matches a base failure when its formatter reports a renamed suite for the same file" do
    provider = Class.new do
      def self.command_for(**)
        "bin/rspec-fast spec/models/widget_spec.rb"
      end
    end
    allow(Syrus::Plugin::Dispatch).to receive(:call).and_call_original
    allow(Syrus::Plugin::Dispatch).to receive(:call)
      .with(:ecosystem, :focused_tests, kind_of(Syrus::Plugin::Context::GraderContext))
      .and_return("bin/rspec-fast spec/models/widget_spec.rb")
    retry_check = described_class.new(
      workflow: workflow, grader_step: grader_step, base_sha: "main123",
      failed_cases: failed_cases, log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |_command, chdir, output|
      path = chdir.join(".syrus/grade-output/rspec-junit.xml")
      FileUtils.mkdir_p(path.dirname)
      path.write(<<~XML)
        <testsuite name="old suite">
          <testcase classname="Renamed::WidgetSpec" file="spec/models/widget_spec.rb" name="Widget fails">
            <failure message="same failure">same failure</failure>
          </testcase>
        </testsuite>
      XML
      output << "1 example, 1 failure"
      command_execution
    end

    expect(retry_check.call).to have_attributes(inherited: true, introduced_failed_identities: [])
  end

  it "matches a uniquely named base failure when native RSpec output has no suite" do
    retry_check = described_class.new(
      workflow: workflow, grader_step: grader_step, base_sha: "main123",
      failed_cases: failed_cases, log: ->(_message) { }
    )

    expect(retry_check.send(:introduced_identities,
      [ "spec/models/widget_spec.rb\0Widget fails" ], [ "unknown\0Widget fails" ])).to be_empty
  end

  it "reuses failed cases from the same grader in a main-grader run at the base SHA" do
    main_job = Factories.job_record(repository: job.repository, kind: "main_grader", issue_number: nil)
    main_workflow = Workflow.create!(job: main_job, trigger_kind: "main_grader", state: "running")
    main_step = Step.create!(
      workflow: main_workflow,
      kind: "grader",
      position: 1,
      state: "failed",
      details: { "name" => "rspec", "command" => "bin/rspec-fast" }
    )
    main_run = main_step.runs.create!(job: main_job, trigger_kind: "main_grader", state: "failed")
    GraderConclusion.create!(
      repository: job.repository,
      job: main_job,
      workflow: main_workflow,
      step: main_step,
      run: main_run,
      commit_sha: "main123",
      grader_fingerprint: "fingerprint",
      grader_name: "rspec",
      status: "failed",
      checked_at: Time.current
    )
    allow(TestEvidenceLookup).to receive(:failed_test_cases_for).with(main_run, "rspec").and_return(failed_cases)
    expect(Syrus::Plugin::Dispatch).not_to receive(:call).with(
      :ecosystem, :focused_tests, kind_of(Syrus::Plugin::Context::GraderContext)
    )

    result = described_class.call(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      failed_cases: failed_cases,
      log: ->(_message) { }
    )

    expect(result).to have_attributes(
      ran: true,
      inherited: true,
      reason: "base_retry_main_grader_failed_cases_match",
      method: "main_grader_result",
      command: nil
    )
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
    allow(Syrus::Plugin::Dispatch).to receive(:call).and_call_original
    allow(Syrus::Plugin::Dispatch).to receive(:call)
      .with(:ecosystem, :focused_tests, kind_of(Syrus::Plugin::Context::GraderContext))
      .and_return("bin/rspec-fast spec/models/widget_spec.rb")
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
      command_execution(skip_reason: "base_retry_timed_out")
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: false,
      inherited: false,
      reason: "base_retry_timed_out",
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
    stub_focused_test_command(provider.command_for)
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
      command_execution
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: false,
      reason: "base_retry_found_introduced_cases"
    )
    expect(result.introduced_failed_identities).to eq([ "spec/models/widget_spec.rb\0Widget fails" ])
  end

  it "keeps the failure when the matching base test errors in the temporary worktree" do
    provider = Class.new do
      def self.command_for(**)
        "bin/rspec-fast spec/models/widget_spec.rb"
      end
    end
    stub_focused_test_command(provider.command_for)
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
            <error message="Missing generated schema">LoadError: cannot load generated/schema</error>
          </testcase>
        </testsuite>
      XML
      output << "1 example, 1 error"
      command_execution
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: false,
      reason: "base_retry_found_introduced_cases",
      base_failed_identities: [],
      introduced_failed_identities: [ "spec/models/widget_spec.rb\0Widget fails" ]
    )
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
      command_execution
    end

    result = retry_check.call

    expect(result.command).to eq("bin/rspec-fast spec/models/widget_spec.rb")
  end

  it "does not run the full grader command when a focused strategy has no structured failed cases" do
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
    expect(retry_check).not_to receive(:run_command)

    result = retry_check.call

    expect(result).to have_attributes(
      ran: false,
      inherited: false,
      reason: "no_structured_cases",
      command: nil
    )
  end

  it "does not run the full grader command when files_as_args cannot synthesize a focused command" do
    grader_step.update!(details: grader_step.details.merge("base_retry" => { "strategy" => "files_as_args" }))
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      failed_cases: failed_cases.map { |test_case| test_case.except("file_path") },
      log: ->(_message) { }
    )
    expect(retry_check).not_to receive(:run_command)

    result = retry_check.call

    expect(result).to have_attributes(
      ran: false,
      inherited: false,
      reason: "focused_command_unavailable",
      command: nil
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
      command_execution(success: false)
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
      command_execution(success: false)
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
      command_execution
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: false,
      reason: "base_retry_full_command_base_passed"
    )
  end

  it "requires an explicit candidate command to pass before comparing it with the base" do
    grader_step.update!(details: {
      "name" => "rspec", "command" => "bundle exec rspec",
      "base_retry" => { "strategy" => "full_command" }
    })
    retry_check = described_class.new(
      workflow:, grader_step:, base_sha: "main123", command: "bundle exec rspec spec/regression_spec.rb",
      require_candidate_pass: true, log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |_command, chdir, output|
      expect(chdir).to eq(@workspace_path)
      output << "1 example, 1 failure"
      command_execution(success: false)
    end

    result = retry_check.call

    expect(result).to have_attributes(ran: true, inherited: false, reason: "candidate_command_failed",
      method: "candidate_command")
  end

  it "uses an explicit command even when the grader normally uses focused plugin retries" do
    retry_check = described_class.new(
      workflow:, grader_step:, base_sha: "main123", command: "bundle exec rspec spec/regression_spec.rb",
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:run_command) do |command, _chdir, output|
      expect(command).to eq("bundle exec rspec spec/regression_spec.rb")
      output << "1 example, 1 failure"
      command_execution(success: false)
    end

    expect(retry_check.call).to have_attributes(ran: true, inherited: true, method: "full_command")
  end

  it "compares the base only after the explicit candidate command passes" do
    grader_step.update!(details: {
      "name" => "rspec", "command" => "bundle exec rspec",
      "base_retry" => { "strategy" => "full_command" }
    })
    retry_check = described_class.new(
      workflow:, grader_step:, base_sha: "main123", command: "bundle exec rspec spec/regression_spec.rb",
      require_candidate_pass: true, log: ->(_message) { }
    )
    calls = 0
    allow(retry_check).to receive(:run_command) do |_command, chdir, output|
      calls += 1
      if chdir == @workspace_path
        command_execution
      else
        output << "1 example, 1 failure"
        command_execution(success: false)
      end
    end

    result = retry_check.call

    expect(calls).to eq(2)
    expect(result).to have_attributes(ran: true, inherited: true)
  end

  it "overlays a new candidate spec and requires its failed example as base evidence" do
    spec_path = @workspace_path.join("spec/regression_spec.rb")
    FileUtils.mkdir_p(spec_path.dirname)
    spec_path.write("RSpec.describe('regression') { it('fails on base') { expect(fixed?).to be(true) } }\n")
    retry_check = described_class.new(
      workflow:, grader_step:, base_sha: "main123", command: "bundle exec rspec spec/regression_spec.rb",
      require_candidate_pass: true, candidate_files: [ "spec/regression_spec.rb" ],
      require_failed_test_evidence: true, log: ->(_message) { }
    )
    allow(retry_check).to receive(:materialize_base_checkout!) do |checkout_path|
      FileUtils.mkdir_p(checkout_path)
      "linked"
    end
    calls = 0
    allow(retry_check).to receive(:run_command) do |_command, chdir, output|
      calls += 1
      if chdir == @workspace_path
        command_execution
      else
        expect(chdir.join("spec/regression_spec.rb").read).to include("fails on base")
        junit = chdir.join(".syrus/rspec-junit/regression.xml")
        FileUtils.mkdir_p(junit.dirname)
        junit.write(<<~XML)
          <testsuite name="spec/regression_spec.rb">
            <testcase classname="spec/regression_spec.rb" file="spec/regression_spec.rb" name="fails on base">
              <failure message="expected fixed?">expected fixed?</failure>
            </testcase>
          </testsuite>
        XML
        output << "1 example, 1 failure"
        command_execution(success: false)
      end
    end

    result = retry_check.call

    expect(calls).to eq(2)
    expect(result).to have_attributes(ran: true, inherited: true)
  end

  it "refuses a base command failure without a failed test example" do
    spec_path = @workspace_path.join("spec/regression_spec.rb")
    FileUtils.mkdir_p(spec_path.dirname)
    spec_path.write("RSpec.describe('regression') { it('runs') { expect(true).to be(true) } }\n")
    retry_check = described_class.new(
      workflow:, grader_step:, base_sha: "main123", command: "bundle exec rspec spec/regression_spec.rb",
      candidate_files: [ "spec/regression_spec.rb" ], require_failed_test_evidence: true,
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:materialize_base_checkout!) do |checkout_path|
      FileUtils.mkdir_p(checkout_path)
      stale_junit = checkout_path.join(".syrus/rspec-junit/stale.xml")
      FileUtils.mkdir_p(stale_junit.dirname)
      stale_junit.write(<<~XML)
        <testsuite name="spec/regression_spec.rb">
          <testcase classname="spec/regression_spec.rb" file="spec/regression_spec.rb" name="stale failure">
            <failure message="stale">stale</failure>
          </testcase>
        </testsuite>
      XML
      "linked"
    end
    allow(retry_check).to receive(:run_command) do |_command, _chdir, output|
      output << "An error occurred while loading spec/regression_spec.rb: missing dependency"
      command_execution(success: false)
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true, inherited: false, reason: "base_retry_missing_failed_test_evidence"
    )
  end

  it "refuses absolute and traversing configured artifact paths without deleting them" do
    checkout_path = @workspace_path.join("cleanup-checkout")
    FileUtils.mkdir_p(checkout_path)
    protected_path = checkout_path.dirname.join("protected.xml")
    protected_path.write("keep me")

    [ protected_path.to_s, "../protected.xml" ].each do |junit_output|
      grader_step.update!(details: grader_step.details.merge("junit_output" => junit_output))

      expect {
        retry_check = described_class.new(
          workflow:, grader_step:, base_sha: "main123", log: ->(_message) { }
        )
        retry_check.send(:clear_parse_artifacts!, checkout_path)
      }.to raise_error(ArgumentError, /artifact path must stay inside/)
      expect(protected_path.read).to eq("keep me")
    end
  end

  it "kills a hung base command when the timeout expires", :allow_host_execution do
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

    expect(result).to have_attributes(ran: false, reason: "base_retry_timed_out")
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

  it "reports an operator-killed focused retry without parsing partial output" do
    provider = Class.new do
      def self.command_for(**)
        "bin/rspec-fast spec/models/widget_spec.rb"
      end
    end
    stub_focused_test_command(provider.command_for)
    allow(ProcessRunner).to receive(:new).and_return(
      instance_double(ProcessRunner, run: process_runner_result(operator_killed: true))
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
    expect(retry_check).not_to receive(:parse_result)

    result = retry_check.call

    expect(result).to have_attributes(ran: false, reason: "base_retry_operator_killed")
  end

  it "reports an operator-killed full-command retry without calling it a timeout" do
    grader_step.update!(details: grader_step.details.merge("base_retry" => { "strategy" => "full_command" }))
    allow(ProcessRunner).to receive(:new).and_return(
      instance_double(ProcessRunner, run: process_runner_result(operator_killed: true))
    )
    retry_check = described_class.new(
      workflow: workflow,
      grader_step: grader_step,
      base_sha: "main123",
      log: ->(_message) { }
    )
    allow(retry_check).to receive(:git) do |*args|
      FileUtils.mkdir_p(args.fetch(3)) if args.first(3) == [ "worktree", "add", "--detach" ]
      ""
    end

    result = retry_check.call

    expect(result).to have_attributes(ran: false, reason: "base_retry_operator_killed")
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
    stub_focused_test_command(provider.command_for)
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
      command_execution
    end

    result = retry_check.call

    expect(result).to have_attributes(
      ran: true,
      inherited: true,
      reason: "base_retry_failed_cases_match"
    )
  end
end
