require "rails_helper"

RSpec.describe Prompts::CiFailure do
  let(:issue) { Struct.new(:title, :body).new("Add greeting helper", "Body of the issue.") }
  let(:checks) do
    [
      { name: "test", conclusion: "failure",   html_url: "https://github.com/x/y/runs/1", summary: "RSpec: 1 failure in greet_spec.rb:14" },
      { name: "lint", conclusion: "timed_out", html_url: "https://github.com/x/y/runs/2", summary: "exceeded 10m wall clock" }
    ]
  end

  def build(**overrides)
    described_class.new(
      issue: issue, pr_number: 7, repo_slug: "acme/widgets",
      branch_name: "syrus/issue-42-1", head_sha: "abc1234567890",
      failed_checks: checks,
      **overrides
    )
  end

  it "names the PR, branch, short SHA, and each failing check" do
    out = build.to_s
    expect(out).to include("acme/widgets#7")
    expect(out).to include("syrus/issue-42-1")
    expect(out).to include("abc1234")    # short SHA
    expect(out).to include("test")
    expect(out).to include("lint")
    expect(out).to include("RSpec: 1 failure in greet_spec.rb:14")
    expect(out).to include("exceeded 10m wall clock")
    expect(out).to include("Structured error context:")
  end

  it "tells the agent to fix the failure and not silence it" do
    out = build.to_s
    expect(out).to match(/Do \*\*not\*\* silence them/)
    expect(out).to match(/submit_summary/)
  end

  it "includes the operator clarification instruction" do
    expect(build.to_s).to include(Prompts::OperatorClarificationInstructions::TEXT)
  end

  it "shows '(no summary provided)' when GitHub omits a summary" do
    out = build(failed_checks: [ { name: "vague", conclusion: "failure", html_url: "u", summary: nil } ]).to_s
    expect(out).to include("(no summary provided)")
  end

  it "truncates very long summaries" do
    big = "x" * (described_class::MAX_SUMMARY_BYTES + 5_000)
    out = build(failed_checks: [ { name: "verbose", conclusion: "failure", html_url: "u", summary: big } ]).to_s
    expect(out).to include("…[truncated]")
    expect(out.bytesize).to be < big.bytesize + 2_000
  end

  it "caps the number of checks rendered" do
    many = Array.new(described_class::MAX_CHECKS + 3) { |i| { name: "check_#{i}", conclusion: "failure", html_url: "u#{i}", summary: "x" } }
    out = build(failed_checks: many).to_s
    expect(out).to include("check_0").and include("check_#{described_class::MAX_CHECKS - 1}")
    expect(out).not_to include("check_#{described_class::MAX_CHECKS + 1}")
  end

  it "renders parsed CI log context as structured JSON" do
    out = build(failed_checks: [
      {
        name: "rspec",
        conclusion: "failure",
        html_url: "https://github.com/x/y/runs/1",
        summary: "RSpec failed",
        error_context: {
          failing_step: "rspec",
          parser: "rspec",
          error_summary: "12 examples, 1 failure",
          failing_tests: [ "GreetingHelper#greet returns the user's name" ],
          offenses: [],
          error_block: "Failure/Error: expect(greet(\"Ada\")).to eq(\"Hello, Ada\")",
          full_log_url: "https://github.com/x/y/runs/1"
        }
      }
    ]).to_s

    expect(out).to include('"parser": "rspec"')
    expect(out).to include('"failing_tests":')
    expect(out).to include("GreetingHelper#greet returns the user's name")
    expect(out).to include("Full log: https://github.com/x/y/runs/1")
  end
end
