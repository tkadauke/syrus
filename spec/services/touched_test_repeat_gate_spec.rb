require "rails_helper"
require "fileutils"
require "tmpdir"

RSpec.describe TouchedTestRepeatGate do
  around do |ex|
    Dir.mktmpdir("syrus-flaky-gate") { |dir| @dir = dir; ex.run }
  end

  # No base_retry at all -- the common case. BaseRevisionRetry's
  # `base_retry: { strategy: plugin }` is a separate, rarely-configured
  # opt-in that this gate must not depend on (see the "no base_retry"
  # examples below), so the default fixture deliberately omits it.
  let(:grader_step) do
    Struct.new(:details).new({ "name" => "rspec", "command" => "bin/rspec" })
  end

  def grader_step_with(details)
    Struct.new(:details).new(details)
  end

  # A fake :focused_test_command provider stands in for Ruby::FocusedTestCommand
  # here -- the point of this spec is the repeat/aggregate logic, not the
  # plugin's own file-matching rules (covered where that plugin lives).
  def stub_focused_command(command)
    provider = double("focused_test_command_provider")
    allow(provider).to receive(:command_for).and_return(command)
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:focused_test_command).and_return([ provider ])
  end

  def write_rails_bin(script)
    FileUtils.mkdir_p(File.join(@dir, "bin"))
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config/database.yml"), "test:\n  adapter: sqlite3\n")
    File.write(File.join(@dir, "bin/rails"), "#!/usr/bin/env bash\n#{script}\n")
    FileUtils.chmod(0o755, File.join(@dir, "bin/rails"))
  end

  it "flags an intentionally-flaky fixture test as inconsistent across repeats" do
    counter = Pathname.new(@dir).join("counter")
    counter.write("0")
    # Alternates fail/pass/fail/pass/fail across 5 runs -- deterministic, no
    # sleeping or subprocess mocking required.
    stub_focused_command(
      "n=$(cat #{counter}); n=$((n+1)); echo $n > #{counter}; test $((n % 2)) -eq 0"
    )

    result = described_class.call(
      grader_step: grader_step,
      touched_files: [ "spec/flaky_spec.rb" ],
      workspace_path: @dir,
      repeats: 5
    )

    expect(result.ran).to be(true)
    expect(result.consistent).to be(false)
    expect(result.inconsistent?).to be(true)
    expect(result.repeats).to eq(5)
    expect(result.pass_count + result.fail_count).to eq(5)
    expect(result.pass_count).to be > 0
    expect(result.fail_count).to be > 0
  end

  it "considers a consistently passing test stable" do
    stub_focused_command("true")

    result = described_class.call(
      grader_step: grader_step,
      touched_files: [ "spec/stable_spec.rb" ],
      workspace_path: @dir,
      repeats: 5
    )

    expect(result.ran).to be(true)
    expect(result.consistent).to be(true)
    expect(result.inconsistent?).to be(false)
    expect(result.pass_count).to eq(5)
    expect(result.fail_count).to eq(0)
  end

  it "forces repeat commands to run in the test environment" do
    stub_focused_command('test "$RAILS_ENV" = test')

    result = described_class.call(
      grader_step: grader_step,
      touched_files: [ "spec/stable_spec.rb" ],
      workspace_path: @dir,
      env: { "RAILS_ENV" => "production" },
      repeats: 1
    )

    expect(result).to have_attributes(ran: true, consistent: true, pass_count: 1, fail_count: 0)
  end

  it "prepares a Rails test database before repeating focused specs" do
    prepared = Pathname.new(@dir).join("prepared")
    write_rails_bin("touch #{prepared}")
    stub_focused_command("test -f #{prepared}")

    result = described_class.call(
      grader_step: grader_step,
      touched_files: [ "spec/stable_spec.rb" ],
      workspace_path: @dir,
      repeats: 1
    )

    expect(result).to have_attributes(ran: true, consistent: true, pass_count: 1, fail_count: 0)
  end

  it "skips the gate when Rails test database setup fails" do
    write_rails_bin("echo setup failed >&2; exit 1")
    stub_focused_command("false")
    messages = []

    result = described_class.call(
      grader_step: grader_step,
      touched_files: [ "spec/stable_spec.rb" ],
      workspace_path: @dir,
      repeats: 1,
      log: ->(message) { messages << message }
    )

    expect(result).to have_attributes(ran: false, consistent: true, reason: "repeat_environment_setup_failed")
    expect(messages.join("\n")).to include("repeat environment setup failed")
  end

  it "treats consistently failing repeats as inconsistent with the grader pass that triggered the gate" do
    stub_focused_command("false")

    result = described_class.call(
      grader_step: grader_step,
      touched_files: [ "spec/broken_spec.rb" ],
      workspace_path: @dir,
      repeats: 5
    )

    expect(result.consistent).to be(false)
    expect(result.inconsistent?).to be(true)
    expect(result.pass_count).to eq(0)
    expect(result.fail_count).to eq(5)
  end

  it "serializes repeat commands in the same workspace" do
    sentinel = Pathname.new(@dir).join("busy")
    stub_focused_command(
      "test ! -e #{sentinel}; touch #{sentinel}; sleep 0.2; rm #{sentinel}"
    )

    calls = Array.new(2) do
      Thread.new do
        described_class.call(
          grader_step: grader_step,
          touched_files: [ "spec/stable_spec.rb" ],
          workspace_path: @dir,
          repeats: 1
        )
      end
    end
    results = calls.map(&:value)

    expect(results).to all(have_attributes(ran: true, consistent: true, pass_count: 1, fail_count: 0))
  end

  it "skips without running anything when there are no touched files" do
    expect(Syrus::PluginRegistry).not_to receive(:providers_for)

    result = described_class.call(
      grader_step: grader_step,
      touched_files: [],
      workspace_path: @dir
    )

    expect(result.ran).to be(false)
    expect(result.reason).to eq("no_touched_files")
  end

  it "skips when no focused_test_command provider can build a command" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:focused_test_command).and_return([])

    result = described_class.call(
      grader_step: grader_step,
      touched_files: [ "spec/foo_spec.rb" ],
      workspace_path: @dir
    )

    expect(result.ran).to be(false)
    expect(result.reason).to eq("no_focused_command")
  end

  describe "building the rerun command without BaseRevisionRetry's base_retry opt-in" do
    # The regression this guards: a repository has never configured
    # `base_retry: { strategy: plugin }` on its rspec grader (most don't --
    # it's a separate feature), so the gate must still be able to build a
    # command via the real, unstubbed Ruby plugin instead of silently
    # declining every time.
    it "asks the real Ruby focused_test_command provider even with no base_retry configured" do
      step = grader_step_with({ "name" => "rspec", "command" => "bundle exec rspec" })

      result = described_class.call(
        grader_step: step,
        touched_files: [ "spec/models/widget_spec.rb" ],
        workspace_path: @dir,
        repeats: 1
      )

      expect(result.ran).to be(true)
      expect(result.command).to eq("bundle exec rspec spec/models/widget_spec.rb")
    end

    it "honors an explicit files_as_args base_retry without involving any plugin" do
      expect(Syrus::PluginRegistry).not_to receive(:providers_for)
      step = grader_step_with({
        "name" => "tests", "command" => "bin/rspec-fast", "base_retry" => { "strategy" => "files_as_args" }
      })

      result = described_class.call(
        grader_step: step,
        touched_files: [ "spec/foo_spec.rb", "spec/bar_spec.rb" ],
        workspace_path: @dir,
        repeats: 1
      )

      expect(result.command).to eq("bin/rspec-fast spec/foo_spec.rb spec/bar_spec.rb")
    end

    it "honors an explicit command base_retry, interpolating {files}" do
      expect(Syrus::PluginRegistry).not_to receive(:providers_for)
      step = grader_step_with({
        "name" => "tests", "command" => "bin/rspec-fast",
        "base_retry" => { "strategy" => "command", "command" => "bin/rspec {files}" }
      })

      result = described_class.call(
        grader_step: step,
        touched_files: [ "spec/foo_spec.rb" ],
        workspace_path: @dir,
        repeats: 1
      )

      expect(result.command).to eq("bin/rspec spec/foo_spec.rb")
    end

    it "declines a full_command base_retry rather than rerunning the whole grader" do
      expect(Syrus::PluginRegistry).not_to receive(:providers_for)
      step = grader_step_with({
        "name" => "tests", "command" => "bin/rspec-fast", "base_retry" => { "strategy" => "full_command" }
      })

      result = described_class.call(
        grader_step: step,
        touched_files: [ "spec/foo_spec.rb" ],
        workspace_path: @dir,
        repeats: 1
      )

      expect(result.ran).to be(false)
      expect(result.reason).to eq("no_focused_command")
    end
  end
end
