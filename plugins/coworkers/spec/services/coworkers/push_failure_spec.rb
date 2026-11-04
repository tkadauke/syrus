require "rails_helper"

RSpec.describe Coworkers::PushFailure do
  def failure(output) = GitRunner::GitError.new([ "push" ], 1, output)

  it "classifies remote 5xx, commit failures, and network failures as transient" do
    [ "remote: Internal Server Error (HTTP 500)", "remote: fatal error in commit_refs",
      "connection reset by peer", "operation timed out" ].each do |output|
      expect(described_class.for(failure(output))).to be_transient, output
    end
  end

  it "classifies authentication, protected refs, and non-fast-forward failures as permanent" do
    [ "Authentication failed", "GH006: Protected branch update failed", "rejected (non-fast-forward)" ].each do |output|
      expect(described_class.for(failure(output))).not_to be_transient, output
    end
  end
end
