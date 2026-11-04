require "rails_helper"
RSpec.describe Coworkers::PushFailure do
  def failure(output) = GitRunner::GitError.new([ "push" ], 1, output)
  it "classifies transient remote and network failures" do
    [ "Internal Server Error (HTTP 500)", "fatal error in commit_refs", "connection reset by peer", "operation timed out" ].each do |output|
      expect(described_class.for(failure(output))).to be_transient, output
    end
  end
  it "keeps auth, protected refs, and conflicts permanent" do
    [ "Authentication failed", "GH006: Protected branch", "rejected (non-fast-forward)" ].each do |output|
      expect(described_class.for(failure(output))).not_to be_transient, output
    end
  end
end
