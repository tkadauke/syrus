require "rails_helper"

RSpec.describe CiLogParser do
  def fixture_log(name)
    Rails.root.join("spec/fixtures/ci_logs/#{name}.log").read
  end

  it "extracts the RSpec failure block and failed example names" do
    result = described_class.new(
      fixture_log("rspec_failure"),
      step_name: "bundle exec rspec",
      full_log_url: "https://github.com/acme/widgets/actions/runs/1"
    ).parse

    expect(result[:parser]).to eq("rspec")
    expect(result[:error_summary]).to eq("12 examples, 1 failure")
    expect(result[:failing_tests]).to include("GreetingHelper#greet returns the user's name")
    expect(result[:error_block]).to include("expected: \"Hello, Ada\"")
    expect(result[:error_block]).not_to include("................................................................")
    expect(result[:full_log_url]).to eq("https://github.com/acme/widgets/actions/runs/1")
  end

  it "extracts RuboCop offenses without the full command log" do
    result = described_class.new(fixture_log("rubocop_failure"), step_name: "rubocop").parse

    expect(result[:parser]).to eq("rubocop")
    expect(result[:error_summary]).to eq("2 files inspected, 2 offenses detected")
    expect(result[:offenses]).to contain_exactly(
      a_string_matching("Style/StringLiterals"),
      a_string_matching("Layout/TrailingWhitespace")
    )
    expect(result[:error_block]).not_to include("Inspecting 2 files")
  end

  it "falls back to context around a generic error marker" do
    result = described_class.new(fixture_log("generic_failure"), step_name: "bin/build").parse

    expect(result[:parser]).to eq("generic_error")
    expect(result[:error_summary]).to eq("Error: Cannot find module '@rollup/rollup-linux-x64-gnu'")
    expect(result[:error_block]).to include("Require stack:")
    expect(result[:error_block]).to include("Process completed with exit code 1.")
  end

  it "extracts Vitest failures after removing ANSI escapes and benign browser warnings" do
    result = described_class.new(fixture_log("vitest_failure"), step_name: "react tests").parse

    expect(result[:parser]).to eq("vitest")
    expect(result[:error_summary]).to match(/Test Files\s+1 failed/)
    expect(result[:failing_tests]).to include("app/frontend/components/Filter.test.tsx > Filter > preserves selected chips")
    expect(result[:error_block]).to include("AssertionError: expected []")
    expect(result[:error_block]).not_to match(/validateDOMNesting|wrapped in act|HTMLCanvasElement|\e\[/)
  end

  it "extracts Playwright's numbered failed spec list" do
    result = described_class.new(fixture_log("playwright_failure"), step_name: "playwright").parse

    expect(result[:parser]).to eq("playwright")
    expect(result[:error_summary]).to eq("2 failed")
    expect(result[:failing_tests]).to contain_exactly(
      "tests/review/job-review.spec.ts:42:3 › review tab › displays annotations",
      "tests/chat/tool-card.spec.ts:19:3 › tool cards › renders output"
    )
  end

  def with_actions_timestamps(log)
    log.lines.each_with_index.map { |line, index| format("2026-11-09T10:52:%02d.2529545Z %s", index % 60, line) }.join
  end

  # Regression: real GitHub Actions job logs carry a timestamp on every line,
  # which kept every line-anchored parser from matching. A failed e2e check
  # fell through to the generic tail -- post-job cleanup -- and the CI-repair
  # agent had no failure to work from.
  it "parses Playwright failures out of a timestamped GitHub Actions log" do
    log = with_actions_timestamps(fixture_log("playwright_failure") + <<~TAIL)
      ##[error]Process completed with exit code 1.
      No files were found with the provided path: playwright-report/. No artifacts will be uploaded.
      Post job cleanup.
    TAIL

    result = described_class.new(log, step_name: "playwright").parse

    expect(result[:parser]).to eq("playwright")
    expect(result[:error_summary]).to eq("2 failed")
    expect(result[:failing_tests]).to include("tests/review/job-review.spec.ts:42:3 › review tab › displays annotations")
    expect(result[:error_block]).to include("expect(locator).toBeVisible() failed")
  end

  it "parses RSpec failures out of a timestamped GitHub Actions log" do
    result = described_class.new(with_actions_timestamps(fixture_log("rspec_failure")), step_name: "bundle exec rspec").parse

    expect(result[:parser]).to eq("rspec")
    expect(result[:error_summary]).to eq("12 examples, 1 failure")
    expect(result[:error_block]).not_to match(/\A2026-11-09T/)
  end

  it "extracts RSpec failed examples even when the detailed failures block is absent" do
    log = <<~LOG
      12 examples, 1 failure

      Failed examples:

      rspec ./spec/models/widget_spec.rb:27 # Widget validates its name
    LOG

    result = described_class.new(log, step_name: "rspec").parse

    expect(result[:parser]).to eq("rspec")
    expect(result[:failing_tests]).to eq([ "./spec/models/widget_spec.rb:27 - Widget validates its name" ])
  end

  it "recognizes lint and TypeScript errors from real command shapes" do
    lint = described_class.new(fixture_log("lint_failure"), step_name: "lint").parse
    typescript = described_class.new(fixture_log("typescript_failure"), step_name: "typecheck").parse

    expect(lint).to include(parser: "generic_error", error_summary: "✖ 1 problem (1 error, 0 warnings)")
    expect(typescript).to include(parser: "typescript", error_summary: "1 TypeScript error(s)")
  end

  it "keeps the tail when a generic log exceeds the context bound" do
    log = ([ "Error: command failed" ] + Array.new(100) { |i| "output #{i}" } + [ "failing assertion at the end" ]).join("\n")

    result = described_class.new(log, step_name: "test").parse

    expect(result[:error_block]).to include("failing assertion at the end")
    expect(result[:error_block]).not_to include("output 1\n")
    expect(result[:error_block].bytesize).to be <= described_class::MAX_BLOCK_BYTES + 20
  end

  it "returns a useful empty result when no log is available" do
    result = described_class.new(nil, step_name: "test", full_log_url: "https://ci.example/log").parse

    expect(result).to include(
      failing_step: "test",
      parser: "empty",
      error_summary: "No CI log was available.",
      error_block: "",
      full_log_url: "https://ci.example/log"
    )
    expect(result[:failing_tests]).to eq([])
    expect(result[:offenses]).to eq([])
  end

  it "scopes parsing to the named CI step before choosing a parser" do
    log = <<~LOG
      step: lint
      app/models/widget.rb:10:5: C: Layout/SpaceInsideHashLiteral: Space inside { missing.
      1 file inspected, 1 offense detected

      step: test
      FAIL spec/javascript/filter.test.mjs
      > preserves selected chips
      Test Files 1 failed, 0 passed
    LOG

    result = described_class.new(log, step_name: "test").parse

    expect(result[:parser]).to eq("js_test")
    expect(result[:error_summary]).to eq("Test Files 1 failed, 0 passed")
    expect(result[:failing_tests]).to contain_exactly(
      "preserves selected chips",
      "spec/javascript/filter.test.mjs"
    )
    expect(result[:error_block]).not_to include("Layout/SpaceInsideHashLiteral")
  end

  it "caps long error blocks" do
    log = <<~LOG
      Failures:

        1) Widget does the thing
           Failure/Error: expect(widget).to be_ready
    LOG
    log += Array.new(100) { |i| "     context line #{i}" }.join("\n")

    result = described_class.new(log, step_name: "rspec").parse

    expect(result[:parser]).to eq("rspec")
    expect(result[:error_block].lines.size).to eq(described_class::MAX_BLOCK_LINES)
    expect(result[:error_block]).to include("context line 75")
    expect(result[:error_block]).not_to include("context line 76")
  end

  describe ":ci_log_parser plugin integration" do
    after { Syrus::PluginRegistry.reset! }

    def ci_log_parser_provider(double)
      Class.new do
        def self.key = :fixture
        def self.display_name = "Fixture"
        define_singleton_method(:parse_ci_log) { |context| double.call(text: context.text, step_name: context.step_name) }
      end
    end

    def register_parser(name, provider)
      register_ecosystem_provider(name:, provider:, provisional: %i[parse_ci_log])
    end

    it "tries a registered plugin before any built-in parser" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_return(
        parser: "python", error_summary: "3 pytest failure(s)", error_block: "traceback...",
        failing_tests: [ "test_foo" ]
      )
      register_parser("python_ci_log_plugin", ci_log_parser_provider(plugin))

      result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse

      expect(plugin).to have_received(:call).with(text: a_string_matching(/Failures:/), step_name: "bundle exec rspec")
      expect(result).to include(
        parser: "python", error_summary: "3 pytest failure(s)",
        error_block: "traceback...", failing_tests: [ "test_foo" ]
      )
    end

    it "falls through to the built-in parsers when the plugin returns nil" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_return(nil)
      register_parser("nil_ci_log_plugin", ci_log_parser_provider(plugin))

      result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse

      expect(plugin).to have_received(:call)
      expect(result[:parser]).to eq("rspec")
      expect(result[:error_summary]).to eq("12 examples, 1 failure")
    end

    it "skips a disabled plugin's parser and falls through to the built-in parsers" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call)
      register_parser("disabled_ci_log_plugin", ci_log_parser_provider(plugin))
      PluginRecord.find_by!(name: "disabled_ci_log_plugin").update!(enabled: false)

      result = described_class.new(fixture_log("rubocop_failure"), step_name: "rubocop").parse

      expect(plugin).not_to have_received(:call)
      expect(result[:parser]).to eq("rubocop")
    end

    it "tries plugins in registration order and uses the first non-nil result" do
      first_plugin = double("first_ci_log_plugin")
      second_plugin = double("second_ci_log_plugin")
      allow(first_plugin).to receive(:call).and_return(nil)
      allow(second_plugin).to receive(:call).and_return(
        parser: "go", error_summary: "1 test failure", error_block: "--- FAIL: TestFoo"
      )
      register_parser("first_ci_log_plugin", ci_log_parser_provider(first_plugin))
      register_parser("second_ci_log_plugin", ci_log_parser_provider(second_plugin))

      result = described_class.new(fixture_log("rspec_failure"), step_name: "test").parse

      expect(first_plugin).to have_received(:call)
      expect(second_plugin).to have_received(:call)
      expect(result[:parser]).to eq("go")
    end

    it "treats a plugin that raises as a non-match and falls through to the built-in parsers" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_raise(StandardError, "boom")
      register_parser("raising_ci_log_plugin", ci_log_parser_provider(plugin))

      result = nil
      expect { result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse }
        .not_to raise_error

      expect(result[:parser]).to eq("rspec")
    end

    it "treats a plugin result missing required keys as a non-match" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_return(failing_tests: [ "test_foo" ])
      register_parser("incomplete_ci_log_plugin", ci_log_parser_provider(plugin))

      result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse

      expect(result[:parser]).to eq("rspec")
    end

    it "treats a non-Hash plugin result as a non-match" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_return("not a hash")
      register_parser("malformed_ci_log_plugin", ci_log_parser_provider(plugin))

      result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse

      expect(result[:parser]).to eq("rspec")
    end

    it "accepts a plugin result with string keys" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_return(
        "parser" => "go", "error_summary" => "1 test failure", "error_block" => "--- FAIL: TestFoo"
      )
      register_parser("string_keyed_ci_log_plugin", ci_log_parser_provider(plugin))

      result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse

      expect(result[:parser]).to eq("go")
      expect(result[:error_summary]).to eq("1 test failure")
    end

    it "leaves built-in Ruby/JS parser output unchanged when no plugins are registered" do
      expect(Syrus::PluginRegistry.capability_providers(:ecosystem, :parse_ci_log)).to be_empty

      rspec_result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse
      expect(rspec_result[:parser]).to eq("rspec")
      expect(rspec_result[:error_summary]).to eq("12 examples, 1 failure")

      rubocop_result = described_class.new(fixture_log("rubocop_failure"), step_name: "rubocop").parse
      expect(rubocop_result[:parser]).to eq("rubocop")
      expect(rubocop_result[:error_summary]).to eq("2 files inspected, 2 offenses detected")
    end
  end
end
