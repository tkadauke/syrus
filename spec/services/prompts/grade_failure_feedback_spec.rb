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
          "command" => "bin/rspec spec/models/user_spec.rb",
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
    expect(out).to include("    Reproduce with: bin/rspec spec/models/user_spec.rb")
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
    expect(out).to include("    Full log: .syrus/grade-output/iteration-2/security.log (may be in the grader checkout; re-run the command above if unavailable here)")
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

  it "does not advise report_main_concern for timeout-only latest grader failures" do
    iterations = [
      [
        { "name" => "react-tests", "status" => "failed", "required" => true, "exit_code" => 1, "output" => "Error: Test timed out in 5000ms." }
      ]
    ]

    out = described_class.new(iterations: iterations).to_s

    expect(out).to include("timeout-only")
    expect(out).to include("inconclusive")
    expect(out).to include("do not call `report_main_concern` solely because")
    expect(out).not_to include("files you did not touch")
  end

  it "does not include report_main_concern guidance when no iterations exist" do
    out = described_class.new(iterations: []).to_s

    expect(out).not_to include("report_main_concern")
  end

  it "advises recording an isolated repro attempt before making a fix when graders fail" do
    iterations = [
      [
        { "name" => "tests", "status" => "failed", "exit_code" => 1, "output" => "failure\n" }
      ]
    ]

    out = described_class.new(iterations: iterations).to_s

    expect(out).to include("record_isolated_repro")
    expect(out).to include("BEFORE making any fix")
  end

  describe "#value" do
    it "returns a legitimate false value instead of falling through to the symbol-key fallback" do
      out = described_class.new(iterations: []).send(:value, { "required" => false }, :required)

      expect(out).to eq(false)
    end
  end

  it "does not advise record_isolated_repro for timeout-only latest grader failures" do
    iterations = [
      [
        { "name" => "react-tests", "status" => "failed", "required" => true, "exit_code" => 1, "output" => "Error: Test timed out in 5000ms." }
      ]
    ]

    out = described_class.new(iterations: iterations).to_s

    expect(out).not_to include("record_isolated_repro")
  end

  # The whole point of archiving the log is that the agent reads the log. The
  # prompt carries a pointer and a preview, and says plainly that the file is
  # complete, so the agent does not treat the preview as the whole story.
  describe "with archived grader logs" do
    let(:iterations) do
      [
        [
          { "name" => "rspec", "status" => "failed", "exit_code" => 1, "command" => "bin/rspec" }
        ]
      ]
    end
    let(:manifest) do
      {
        "1" => [
          {
            "name" => "rspec",
            "iteration" => 1,
            "status" => "failed",
            "relative_path" => ".syrus/grade-logs/iteration-1/rspec.log",
            "bytes" => 91_100,
            "preview" => "rspec ./spec/thing_spec.rb:9 # Thing is broken"
          }
        ]
      }
    end

    it "points at the full log and tells the agent to read it" do
      out = described_class.new(iterations: iterations, log_manifest: manifest).to_s

      expect(out).to include(".syrus/grade-logs/iteration-1/rspec.log")
      expect(out).to include("complete and untruncated")
      expect(out).to include("Read that file before changing anything")
      expect(out).to include("rspec ./spec/thing_spec.rb:9")
    end

    it "tells the agent the archived logs hold the complete output" do
      out = described_class.new(iterations: iterations, log_manifest: manifest).to_s

      expect(out).to include("complete output with nothing removed")
      expect(out).not_to include("re-run the\n          exact command shown")
    end

    it "does not dump the grader output inline when a log was archived" do
      noisy = iterations.deep_dup
      noisy[0][0]["output"] = "GIANT INLINE DUMP\n" * 200

      out = described_class.new(iterations: noisy, log_manifest: manifest).to_s

      expect(out).not_to include("GIANT INLINE DUMP")
    end

    # A grader that produced nothing is inconclusive, not a defect. Saying so
    # stops the next agent inventing a fix for a failure it cannot see.
    it "explains a grader that produced no output rather than rendering a blank" do
      empty = {
        "1" => [
          {
            "name" => "rspec",
            "iteration" => 1,
            "status" => "failed",
            "bytes" => 0,
            "unavailable_reason" => "the grader Step never started, so no output was produced"
          }
        ]
      }

      out = described_class.new(iterations: iterations, log_manifest: empty).to_s

      expect(out).to include("No output was captured for this grader")
      expect(out).to include("never started")
      expect(out).to include("inconclusive")
    end

    it "keeps the old inline rendering when nothing was archived" do
      inline = iterations.deep_dup
      inline[0][0]["output"] = "expected true to equal false\n"

      out = described_class.new(iterations: inline).to_s

      expect(out).to include("expected true to equal false")
      expect(out).to include("re-run the")
    end
  end
end
