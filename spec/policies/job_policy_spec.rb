require "rails_helper"

RSpec.describe JobPolicy do
  # The first User created in the process is auto-promoted to admin
  # (User#promote_first_user_to_admin) — create the admin first so the
  # other lets are guaranteed non-admin regardless of reference order.
  let(:admin) { Factories.user(admin: true) }
  let(:owner) { admin && Factories.user }
  let(:other_user) { admin && Factories.user }
  let(:member) { admin && Factories.user }
  let(:job) { Factories.job_record(user: owner) }

  before do
    RepositoryMembership.create!(repository: job.repository, user: member, role: "collaborator")
  end

  describe "#show?" do
    it "allows the owning user" do
      expect(described_class.new(owner, job)).to be_show
    end

    it "allows a user with repository membership who does not own the job" do
      expect(described_class.new(member, job)).to be_show
    end

    it "denies a user with no membership on the job's repository" do
      expect(described_class.new(other_user, job)).not_to be_show
    end

    it "allows a global admin regardless of ownership" do
      expect(described_class.new(admin, job)).to be_show
    end
  end

  describe "#update?" do
    it "allows the owning user" do
      expect(described_class.new(owner, job)).to be_update
    end

    it "denies a repository member who does not own the job -- mutation actions stay creator-or-admin-only" do
      expect(described_class.new(member, job)).not_to be_update
    end

    it "denies a user with no membership on the job's repository" do
      expect(described_class.new(other_user, job)).not_to be_update
    end

    it "allows a global admin regardless of ownership" do
      expect(described_class.new(admin, job)).to be_update
    end
  end

  describe "Scope#resolve" do
    it "returns jobs on repositories the user is a member of, matching Job.accessible_to (mirrors Epic)" do
      owned = job
      Factories.job_record(user: other_user)

      resolved = described_class::Scope.new(owner, Job).resolve

      expect(resolved).to contain_exactly(owned)
    end

    it "includes jobs owned by other members of a shared repository" do
      owned = job

      resolved = described_class::Scope.new(member, Job).resolve

      expect(resolved).to contain_exactly(owned)
    end

    it "excludes jobs on repositories the user has no membership on" do
      job
      foreign = Factories.job_record(user: other_user)

      resolved = described_class::Scope.new(owner, Job).resolve

      expect(resolved).not_to include(foreign)
    end

    it "does not bypass for a global admin (only the per-record predicates do)" do
      job
      foreign = Factories.job_record(user: other_user)

      resolved = described_class::Scope.new(admin, Job).resolve

      expect(resolved).not_to include(foreign)
    end
  end
end
