require "rails_helper"

RSpec.describe RefMovementAction do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe "validations" do
    it "requires action_name" do
      record = described_class.new(repository: repository, requested_by_user: user, state: "blocked")

      expect(record).not_to be_valid
      expect(record.errors[:action_name]).to be_present
    end

    it "requires state to be one of dispatched/blocked" do
      record = described_class.new(repository: repository, requested_by_user: user, action_name: "send_job_upstream", state: "bogus")

      expect(record).not_to be_valid
      expect(record.errors[:state]).to be_present
    end

    it "defaults grade_phases to an empty array" do
      record = described_class.new(repository: repository, requested_by_user: user, action_name: "send_job_upstream", state: "blocked")

      expect(record.grade_phases).to eq([])
    end
  end

  describe ".dispatch!" do
    it "delegates to RefMovementActions::Base.for(action)" do
      handler = instance_double(RefMovementActions::SendJobUpstream)
      allow(RefMovementActions::Base).to receive(:for).with("send_job_upstream").and_return(handler)
      expect(handler).to receive(:dispatch!).with(repository: repository, actor: user, action: "send_job_upstream", source: nil, target: nil)

      described_class.dispatch!(repository: repository, actor: user, action: "send_job_upstream")
    end

    it "records a blocked row for an unsupported action name" do
      record = described_class.dispatch!(repository: repository, actor: user, action: "totally_unsupported")

      expect(record).to be_blocked
      expect(record.blocked_reason).to include("unsupported ref-movement action")
    end
  end

  describe "#dispatched?/#blocked?" do
    it "reflects the persisted state" do
      dispatched = described_class.new(state: "dispatched")
      blocked = described_class.new(state: "blocked")

      expect(dispatched).to be_dispatched
      expect(dispatched).not_to be_blocked
      expect(blocked).to be_blocked
      expect(blocked).not_to be_dispatched
    end
  end
end
