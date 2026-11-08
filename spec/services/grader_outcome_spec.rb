require "rails_helper"

RSpec.describe GraderOutcome do
  def classify(details, state: "failed", run_outcome: nil)
    described_class.call(details: details, state: state, run_outcome: run_outcome)
  end

  it "classifies a succeeded step as passed" do
    expect(classify({ "exit_code" => 0 }, state: "succeeded").outcome).to eq("passed")
  end

  it "classifies a non-zero exit with captured output as test_failed" do
    result = classify({ "exit_code" => 1, "output" => "1 example, 1 failure", "command" => "rspec" })
    expect(result.outcome).to eq("test_failed")
    expect(result.evidence).to include("command" => "rspec", "exit_code" => 1)
  end

  it "does not call a null exit_code with passing output a test failure" do
    result = classify({ "exit_code" => nil, "output" => "120 examples, 0 failures" })
    expect(result.outcome).to eq("inconclusive")
    expect(result.reason).to eq("missing_exit_status")
  end

  it "treats blank results after worker death as infrastructure" do
    result = classify({ "exit_code" => nil, "output" => "" }, run_outcome: "worker_died")
    expect(result.outcome).to eq("infrastructure_failed")
  end

  it "treats database lock timeouts as infrastructure even with a non-zero exit" do
    result = classify({ "exit_code" => 1, "output" => "SQLite3::BusyException: database is locked" })
    expect(result.outcome).to eq("infrastructure_failed")
  end

  it "treats dependency-install failures as infrastructure" do
    result = classify({ "exit_code" => 5, "output" => "An error occurred while installing nokogiri" })
    expect(result.outcome).to eq("infrastructure_failed")
  end

  it "treats timeouts as inconclusive" do
    expect(classify({ "exit_code" => 124, "timed_out" => true, "output" => "x" }).outcome).to eq("inconclusive")
  end

  it "treats invalid exit status or missing evidence as inconclusive" do
    expect(classify({ "exit_code" => -1, "output" => "boom" }).reason).to eq("invalid_exit_status")
    expect(classify({ "exit_code" => 1, "output" => "", "log_bytes" => 0 }).reason).to eq("missing_failure_evidence")
  end

  it "classifies cancelled graders" do
    expect(classify({ "exit_code" => nil, "cancelled" => true }).outcome).to eq("cancelled")
  end
end
