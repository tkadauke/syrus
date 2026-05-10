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
end
