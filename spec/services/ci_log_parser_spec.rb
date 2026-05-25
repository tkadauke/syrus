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
end
