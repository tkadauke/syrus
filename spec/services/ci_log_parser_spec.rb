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
        include Syrus::Plugin::CiLogParser

        define_singleton_method(:call) { |text:, step_name: nil| double.call(text: text, step_name: step_name) }
      end
    end

    it "tries a registered plugin before any built-in parser" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_return(
        parser: "python", error_summary: "3 pytest failure(s)", error_block: "traceback...",
        failing_tests: [ "test_foo" ]
      )
      Syrus::PluginRegistry.register(
        name: "python_ci_log_plugin", version: "1.0.0",
        provides: { ci_log_parser: ci_log_parser_provider(plugin) }
      )

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
      Syrus::PluginRegistry.register(
        name: "nil_ci_log_plugin", version: "1.0.0",
        provides: { ci_log_parser: ci_log_parser_provider(plugin) }
      )

      result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse

      expect(plugin).to have_received(:call)
      expect(result[:parser]).to eq("rspec")
      expect(result[:error_summary]).to eq("12 examples, 1 failure")
    end

    it "skips a disabled plugin's parser and falls through to the built-in parsers" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call)
      Syrus::PluginRegistry.register(
        name: "disabled_ci_log_plugin", version: "1.0.0",
        provides: { ci_log_parser: ci_log_parser_provider(plugin) }
      )
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
      Syrus::PluginRegistry.register(
        name: "first_ci_log_plugin", version: "1.0.0",
        provides: { ci_log_parser: ci_log_parser_provider(first_plugin) }
      )
      Syrus::PluginRegistry.register(
        name: "second_ci_log_plugin", version: "1.0.0",
        provides: { ci_log_parser: ci_log_parser_provider(second_plugin) }
      )

      result = described_class.new(fixture_log("rspec_failure"), step_name: "test").parse

      expect(first_plugin).to have_received(:call)
      expect(second_plugin).to have_received(:call)
      expect(result[:parser]).to eq("go")
    end

    it "treats a plugin that raises as a non-match and falls through to the built-in parsers" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_raise(StandardError, "boom")
      Syrus::PluginRegistry.register(
        name: "raising_ci_log_plugin", version: "1.0.0",
        provides: { ci_log_parser: ci_log_parser_provider(plugin) }
      )

      result = nil
      expect { result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse }
        .not_to raise_error

      expect(result[:parser]).to eq("rspec")
    end

    it "treats a plugin result missing required keys as a non-match" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_return(failing_tests: [ "test_foo" ])
      Syrus::PluginRegistry.register(
        name: "incomplete_ci_log_plugin", version: "1.0.0",
        provides: { ci_log_parser: ci_log_parser_provider(plugin) }
      )

      result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse

      expect(result[:parser]).to eq("rspec")
    end

    it "treats a non-Hash plugin result as a non-match" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_return("not a hash")
      Syrus::PluginRegistry.register(
        name: "malformed_ci_log_plugin", version: "1.0.0",
        provides: { ci_log_parser: ci_log_parser_provider(plugin) }
      )

      result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse

      expect(result[:parser]).to eq("rspec")
    end

    it "accepts a plugin result with string keys" do
      plugin = double("ci_log_parser_plugin")
      allow(plugin).to receive(:call).and_return(
        "parser" => "go", "error_summary" => "1 test failure", "error_block" => "--- FAIL: TestFoo"
      )
      Syrus::PluginRegistry.register(
        name: "string_keyed_ci_log_plugin", version: "1.0.0",
        provides: { ci_log_parser: ci_log_parser_provider(plugin) }
      )

      result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse

      expect(result[:parser]).to eq("go")
      expect(result[:error_summary]).to eq("1 test failure")
    end

    it "leaves built-in Ruby/JS parser output unchanged when no plugins are registered" do
      expect(Syrus::PluginRegistry.providers_for(:ci_log_parser)).to be_empty

      rspec_result = described_class.new(fixture_log("rspec_failure"), step_name: "bundle exec rspec").parse
      expect(rspec_result[:parser]).to eq("rspec")
      expect(rspec_result[:error_summary]).to eq("12 examples, 1 failure")

      rubocop_result = described_class.new(fixture_log("rubocop_failure"), step_name: "rubocop").parse
      expect(rubocop_result[:parser]).to eq("rubocop")
      expect(rubocop_result[:error_summary]).to eq("2 files inspected, 2 offenses detected")
    end
  end
end
