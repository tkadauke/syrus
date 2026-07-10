require "rails_helper"

RSpec.describe Prompts::GradeFailureFeedback do
  it "renders a placeholder when no iterations have been recorded" do
    out = described_class.new(iterations: []).to_s

    expect(out).to start_with("No prior quality grader iterations were recorded yet.")
    expect(out).to end_with(Prompts::GitSafety::TEXT)
  end

  it "renders a single iteration with mixed pass, fail, and skipped results" do
    iterations = [
      [
        { "name" => "lint", "status" => "passed" },
        {
          "name" => "tests",
          "status" => "failed",
          "exit_code" => 1,
          "duration_s" => 23.4,
          "output" => "expected true to equal false\n",
          "log_path" => ".syrus/grade-output/iteration-1/tests.log"
        },
        { "name" => "security", "status" => "skipped", "reason" => "earlier required grader failed" }
      ]
    ]

    out = described_class.new(iterations: iterations).to_s

    expect(out).to include("== Iteration 1 ==")
    expect(out).to include("  ✓ lint")
    expect(out).to include("  ✗ tests (exit 1, 23.4s)")
    expect(out).to include("    expected true to equal false")
    expect(out).to include("  - security (skipped - earlier required grader failed)")
  end

  it "renders the full trajectory across multiple iterations" do
    iterations = [
      [
        { name: "tests", status: "failed", exit_code: 1, duration_s: 8.2, output: "first failure\n" }
      ],
      [
        { name: "tests", status: "passed" },
        { name: "lint", status: "failed", exit_code: 1, duration_s: 4.1, output: "second failure\n" }
      ]
    ]

    out = described_class.new(iterations: iterations).to_s

    expect(out.index("== Iteration 1 ==")).to be < out.index("== Iteration 2 ==")
    expect(out).to include("  ✗ tests (exit 1, 8.2s)")
    expect(out).to include("    first failure")
    expect(out).to include("  ✓ tests")
    expect(out).to include("  ✗ lint (exit 1, 4.1s)")
    expect(out).to include("    second failure")
  end

  it "inlines output at the 32 KB limit" do
    output = "a" * (32 * 1024)
    iterations = [
      [
        { name: "tests", status: "failed", exit_code: 1, output: output }
      ]
    ]

    out = described_class.new(iterations: iterations).to_s

    expect(out).to include("    #{"a" * 80}")
    expect(out).not_to include("[truncated")
    expect(out).not_to include("Full log:")
  end

  it "truncates output over 32 KB with head, tail, byte count, and full log path" do
    head = "h" * (4 * 1024)
    middle = "m" * 25_000
    tail = "t" * (8 * 1024)
    output = head + middle + tail
    iterations = [
      [
        {
          name: "security",
          status: "failed",
          exit_code: 1,
          duration_s: 18.3,
          output: output,
          log_path: ".syrus/grade-output/iteration-2/security.log"
        }
      ]
    ]

    out = described_class.new(iterations: iterations).to_s

    expect(out).to include("  ✗ security (exit 1, 18.3s, output 37 KB - truncated)")
    expect(out).to include("    Head:")
    expect(out).to include("      #{"h" * 80}")
    expect(out).to include("    ... [truncated 25000 bytes] ...")
    expect(out).to include("    Tail:")
    expect(out).to include("      #{"t" * 80}")
    expect(out).to include("    Full log: .syrus/grade-output/iteration-2/security.log")
    expect(out).not_to include("m" * 80)
  end

  it "does not append submit_summary instructions (the grade-loop iteration's agent should not submit a summary)" do
    out = described_class.new(iterations: [ [ { name: "tests", status: "passed" } ] ]).to_s

    expect(out).not_to include("CALL THE `submit_summary` MCP TOOL")
    expect(out).not_to include(Prompts::SubmitSummaryInstructions::TEXT)
  end

  it "advises calling report_main_concern when graders fail in unmodified files" do
    iterations = [
      [
        { "name" => "tests", "status" => "failed", "exit_code" => 1, "output" => "failure\n" }
      ]
    ]

    out = described_class.new(iterations: iterations).to_s

    expect(out).to include("report_main_concern")
    expect(out).to include("files you did not touch")
  end

  it "does not include report_main_concern guidance when no iterations exist" do
    out = described_class.new(iterations: []).to_s

    expect(out).not_to include("report_main_concern")
  end
end
