require "rails_helper"

RSpec.describe Coworkers::PushFailure do
  def failure(output)
    GitRunner::GitError.new([ "push", "origin", "HEAD:refs/heads/test" ], 1, output)
  end

  it "classifies GitHub 5xx, commit_refs, and network timeouts as transient" do
    [
      "remote: Internal Server Error (HTTP 500)",
      "remote: fatal error in commit_refs",
      "fatal: unable to access remote: Connection reset by peer",
      "operation timed out"
    ].each do |output|
      expect(described_class.for(failure(output))).to be_transient, output
    end
  end

  it "classifies authentication, protected refs, and non-fast-forward conflicts as permanent" do
    [
      "remote: Authentication failed",
      "remote: error: GH006: Protected branch update failed",
      "[rejected] main -> main (non-fast-forward)"
    ].each do |output|
      classification = described_class.for(failure(output))
      expect(classification).not_to be_transient, output
      expect(classification.kind).to eq("permanent")
    end
  end
end
