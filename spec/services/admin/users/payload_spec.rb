require "rails_helper"

RSpec.describe Admin::Users::Payload do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }
  let(:target) { Factories.user(role: "developer", scheduling_paused: false) }
  let(:payload) { described_class.new(params: {}, actor: non_admin) }

  describe "privileged mutations" do
    it "rejects scheduling pauses from a non-admin actor" do
      expect {
        payload.pause_scheduling(target.id)
      }.to raise_error(ArgumentError, "Admin access required.")

      expect(target.reload.scheduling_paused?).to be(false)
      expect(AdminAction.count).to eq(0)
    end

    it "rejects scheduling unpauses from a non-admin actor" do
      target.update!(scheduling_paused: true)

      expect {
        payload.unpause_scheduling(target.id)
      }.to raise_error(ArgumentError, "Admin access required.")

      expect(target.reload.scheduling_paused?).to be(true)
      expect(AdminAction.count).to eq(0)
    end

    it "rejects role updates from a non-admin actor" do
      expect {
        payload.update(target.id, role: "product_owner")
      }.to raise_error(ArgumentError, "Admin access required.")

      expect(target.reload.role).to eq("developer")
      expect(AdminAction.count).to eq(0)
    end
  end
end
