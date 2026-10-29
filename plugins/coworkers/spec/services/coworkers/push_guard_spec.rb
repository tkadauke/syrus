require "rails_helper"

RSpec.describe Coworkers::PushGuard do
  let(:coworker) { instance_double(Coworkers::Coworker, id: 7, handle: "maya") }
  subject(:guard) { described_class.new(coworker: coworker) }

  it "allows only the coworker's home and immutable chat branches" do
    expect { guard.validate!("HEAD:refs/heads/coworkers/maya", "HEAD:refs/heads/coworkers/chat/7-42") }
      .not_to raise_error
  end

  it "rejects refs outside the coworker namespace and another coworker's refs" do
    expect { guard.validate!("HEAD:refs/heads/main") }.to raise_error(described_class::Rejected)
    expect { guard.validate!("HEAD:refs/heads/coworkers/nora") }.to raise_error(described_class::Rejected, /foreign ref/)
    expect { guard.validate!("HEAD:refs/heads/coworkers/chat/8-42") }.to raise_error(described_class::Rejected, /foreign ref/)
  end
end
