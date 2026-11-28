require "rails_helper"
require Rails.root.join("lib/failure_corpus/replay").to_s

# Decision drift: the current failure classifier and AutoRetryJob's
# retryability recheck, replayed against real production failures
# (spec/fixtures/failure_corpus, exported by bin/export-failure-corpus).
# Unit specs keep passing when a classifier change misreads real failure
# text; this is the check that sees it.
RSpec.describe FailureCorpus::Replay do
  def kase(id:, error_class: "RuntimeError", error_message: "boom", recorded:, retryable:, step_kind: "implement", attempts: [], logs: [])
    {
      "id" => id,
      "run" => { "trigger_kind" => "initial", "agent_provider" => "claude", "agent_outcome" => nil },
      "step_kind" => step_kind,
      "workflow" => { "trigger_kind" => "initial" },
      "diagnostic" => { "error_class" => error_class, "error_message" => error_message },
      "logs" => logs,
      "spawned_processes" => [],
      "context" => {},
      "recorded" => { "classification" => recorded, "retryable" => retryable },
      "auto_retry_attempts" => attempts
    }
  end

  describe "the production corpus" do
    it "replays with every retryability and recheck change acknowledged" do
      cases = described_class.load_cases
      expect(cases.size).to be >= 100

      report = described_class.new(cases: cases, allowlist: described_class.load_allowlist).call

      expect(report.ok?).to be(true), report.to_s
    end
  end

  describe "comparison" do
    it "fails on an unacknowledged retryability flip" do
      flipped = kase(id: "exited", error_message: "agent exited 1", recorded: "application_error", retryable: false)

      report = described_class.new(cases: [ flipped ]).call

      expect(report.ok?).to be(false)
      expect(report.failures.map(&:transition)).to eq([ "application_error/final -> provider_transient/retryable" ])
      expect(report.to_s).to include("!! exited")
    end

    it "accepts a flip the allowlist acknowledges with the same verdict" do
      flipped = kase(id: "exited", error_message: "agent exited 1", recorded: "application_error", retryable: false)
      allowlist = [ { "status" => "intentional", "reason" => "bare agent exits are transient", "to" => "provider_transient/retryable", "cases" => [ "exited" ] } ]

      report = described_class.new(cases: [ flipped ], allowlist: allowlist).call

      expect(report.ok?).to be(true), report.to_s
      expect(report.changes.first.acknowledged_by).to eq("bare agent exits are transient")
    end

    it "does not let an acknowledgement for a different verdict cover a flip" do
      flipped = kase(id: "exited", error_message: "agent exited 1", recorded: "application_error", retryable: false)
      allowlist = [ { "status" => "intentional", "reason" => "something else", "to" => "worker_died/retryable", "cases" => [ "exited" ] } ]

      report = described_class.new(cases: [ flipped ], allowlist: allowlist).call

      expect(report.failures.size).to eq(1)
      expect(report.stale.map(&:problem)).to eq([ "now replays as provider_transient/retryable" ])
    end

    it "flags an acknowledgement whose case no longer changes" do
      unchanged = kase(id: "same", error_message: "agent exited 1", recorded: "provider_transient", retryable: true)
      allowlist = [
        { "status" => "intentional", "reason" => "already matches", "to" => "provider_transient/retryable", "cases" => [ "same" ] },
        { "status" => "intentional", "reason" => "gone", "to" => "timeout/retryable", "cases" => [ "missing" ] }
      ]

      report = described_class.new(cases: [ unchanged ], allowlist: allowlist).call

      expect(report.ok?).to be(false)
      expect(report.stale.map(&:problem)).to contain_exactly(
        "the recorded verdict already matches; the acknowledgement is unnecessary",
        "no such case in the corpus"
      )
    end

    it "reports a classification change that keeps retryability without failing" do
      relabeled = kase(id: "relabel", error_message: "agent exited 1", recorded: "worker_died", retryable: true)

      report = described_class.new(cases: [ relabeled ]).call

      expect(report.ok?).to be(true)
      expect(report.changes.map(&:kind)).to eq([ "classification" ])
    end

    it "fails when the retryability recheck now skips a retry production performed" do
      diverged = kase(
        id: "diverged",
        error_class: "Steps::PrOpen::BranchDiverged",
        error_message: "PR branch changed before Syrus could push",
        recorded: "branch_diverged",
        retryable: false,
        step_kind: "pr_open",
        attempts: [ { "retry_kind" => "retry_workflow", "failure_classification" => "timeout", "performed" => true } ]
      )

      report = described_class.new(cases: [ diverged ]).call

      expect(report.failures.map { |change| [ change.case_id, change.transition ] })
        .to eq([ [ "diverged#attempt-1", "recheck:retry -> recheck:skip" ] ])
    end

    it "ignores attempts whose recorded outcome says nothing about the recheck" do
      diverged = kase(
        id: "diverged",
        error_class: "Steps::PrOpen::BranchDiverged",
        error_message: "PR branch changed before Syrus could push",
        recorded: "branch_diverged",
        retryable: false,
        step_kind: "pr_open",
        attempts: [ { "retry_kind" => "retry_workflow", "failure_classification" => "timeout", "performed" => false, "skipped_reason" => "source workflow was already superseded" } ]
      )

      expect(described_class.new(cases: [ diverged ]).call.changes).to be_empty
    end

    it "keeps a suspected regression visible in the report while acknowledging it" do
      flipped = kase(id: "exited", error_message: "agent exited 1", recorded: "application_error", retryable: false)
      allowlist = [ { "status" => "suspected_regression", "reason" => "looks wrong", "to" => "provider_transient/retryable", "cases" => [ "exited" ] } ]

      report = described_class.new(cases: [ flipped ], allowlist: allowlist).call

      expect(report.ok?).to be(true)
      expect(report.acknowledged("suspected_regression").map(&:case_id)).to eq([ "exited" ])
      expect(report.to_s).to include("XX exited", "[suspected_regression] looks wrong", "1 suspected_regression")
    end

    it "rejects an acknowledgement without a known status" do
      allowlist = [ { "reason" => "why", "to" => "timeout/retryable", "cases" => [ "x" ] } ]

      expect { described_class.new(cases: [], allowlist: allowlist) }.to raise_error(ArgumentError, /status must be one of/)
    end

    it "compares a repair-declared verdict with what re-classifying leaves behind" do
      # A repair's verdict survives re-classification even when the Run's text
      # matches a branch: a grader the repair killed mid-run still reads
      # "grader rspec failed".
      kept = kase(id: "kept", error_class: "Steps::Base::StepFailed", error_message: "grader rspec failed (exit 1)",
                  recorded: "workspace_recovery_failed", retryable: true, step_kind: "grader")
      kept["recorded"].merge!("source" => "external", "confidence" => 1.0)
      # The same text under a verdict the classifier wrote is re-derived.
      rederived = kase(id: "rederived", error_class: "Steps::Base::StepFailed", error_message: "grader rspec failed (exit 1)",
                       recorded: "timeout", retryable: true, step_kind: "grader")
      rederived["recorded"].merge!("source" => "classifier", "confidence" => 0.85)

      report = described_class.new(cases: [ kept, rederived ]).call

      expect(report.changes.map { |change| [ change.case_id, change.transition ] })
        .to eq([ [ "rederived", "timeout/retryable -> grader_failure/final" ] ])
    end

    it "replays explicit rate-limit logs through the classifier's database read" do
      limited = kase(id: "limited", error_message: "agent stopped", recorded: "rate_limited", retryable: true,
                     logs: [ { "kind" => "rate_limited", "chunk" => "rate limited by provider" } ])

      expect(described_class.new(cases: [ limited ]).call.changes).to be_empty
    end
  end
end
