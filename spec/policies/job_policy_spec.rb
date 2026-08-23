require "rails_helper"

RSpec.describe JobPolicy do
  # The first User created in the process is auto-promoted to admin
  # (User#promote_first_user_to_admin) — create the admin first so the
  # other lets are guaranteed non-admin regardless of reference order.
  let(:admin) { Factories.user(admin: true) }
  let(:owner) { admin && Factories.user }
  let(:other_user) { admin && Factories.user }
  let(:job) { Factories.job_record(user: owner) }

  describe "#show?" do
    it "allows the owning user" do
      expect(described_class.new(owner, job)).to be_show
    end

    it "denies a non-owning user" do
      expect(described_class.new(other_user, job)).not_to be_show
    end

    it "allows a global admin regardless of ownership" do
      expect(described_class.new(admin, job)).to be_show
    end
  end

  describe "Scope#resolve" do
    it "returns only the user's own jobs, matching Current.user.jobs" do
      owned = job
      Factories.job_record(user: other_user)

      resolved = described_class::Scope.new(owner, Job).resolve

      expect(resolved).to contain_exactly(owned)
    end

    it "does not bypass for a global admin (only the per-record predicates do)" do
      job
      foreign = Factories.job_record(user: other_user)

      resolved = described_class::Scope.new(admin, Job).resolve

      expect(resolved).not_to include(foreign)
    end
  end
end
