require "rails_helper"

RSpec.describe Permissions::CoworkerCutoverDeploymentGuard do
  let(:now) { Time.utc(2026, 11, 1, 12) }
  let(:evidence) do
    {
      "target_sha" => "abcdef123456", "verified_at" => now.iso8601,
      "descriptors" => { "complete" => true, "command" => "bin/rails runner validator.validate!" },
      "schema" => { "compatible" => true, "command" => "bin/check-migrations" },
      "parity" => { "samples" => 100, "mismatches" => 0, "evaluation_failures" => 0 },
      "cutover_report" => { "ready" => true, "acknowledged_by" => "operator@example.test", "acknowledged_at" => now.iso8601 },
      "suites" => {
        "evaluator" => { "passed" => true, "command" => "bin/rspec spec/services/permissions" },
        "dispatch" => { "passed" => true, "command" => "bin/rspec spec/services/pending_actions/coworker_tool_call_spec.rb" }
      },
      "rollback" => { "image_sha" => "123456abcdef", "succeeded" => true, "verified_at" => now.iso8601, "command" => "deploy previous image and smoke test" }
    }
  end

  def artifact_for(payload)
    file = Tempfile.new([ "cutover", ".json" ])
    file.write(JSON.generate("evidence" => payload, "sha256" => described_class.digest(payload)))
    file.close
    file
  end

  it "accepts complete, fresh, commit-bound deployment evidence" do
    artifact = artifact_for(evidence)

    expect(described_class.new(path: artifact.path, target_sha: "abcdef1", previous_sha: "123456a", now: now).verify!).to be(true)
  ensure
    artifact&.unlink
  end

  it "reports every missing deployment safeguard together" do
    broken = evidence.deep_merge(
      "descriptors" => { "complete" => false }, "schema" => { "compatible" => false },
      "parity" => { "samples" => 0, "mismatches" => 2, "evaluation_failures" => 1 },
      "cutover_report" => { "ready" => false },
      "suites" => { "evaluator" => { "passed" => false }, "dispatch" => { "passed" => false } },
      "rollback" => { "image_sha" => "wrong", "succeeded" => false }
    )
    artifact = artifact_for(broken)

    expect {
      described_class.new(path: artifact.path, target_sha: "abcdef1", previous_sha: "123456a", now: now).verify!
    }.to raise_error(described_class::VerificationError) { |error|
      expect(error.message).to include(
        "capability descriptors are incomplete", "schema compatibility is unverified",
        "permission parity mismatch threshold was exceeded", "cutover report is not ready",
        "evaluator suite did not pass", "dispatch suite did not pass", "deployment rollback is not verified"
      )
    }
  ensure
    artifact&.unlink
  end

  it "rejects modified or stale evidence" do
    artifact = artifact_for(evidence.merge("verified_at" => (now - 8.days).iso8601))
    payload = JSON.parse(File.read(artifact.path))
    payload["evidence"]["schema"]["compatible"] = false
    File.write(artifact.path, JSON.generate(payload))

    expect {
      described_class.new(path: artifact.path, target_sha: "abcdef1", previous_sha: "123456a", now: now).verify!
    }.to raise_error(described_class::VerificationError, /digest.*older/m)
  ensure
    artifact&.unlink
  end
end
