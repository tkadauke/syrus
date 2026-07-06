require "rails_helper"

RSpec.describe InstallationLinker do
  let(:user) { Factories.user }

  describe ".find_for_owner" do
    it "returns nil for a blank owner" do
      expect(described_class.find_for_owner(nil)).to be_nil
      expect(described_class.find_for_owner("")).to be_nil
    end

    it "returns the active installation matching the owner (case-insensitive)" do
      installation = Factories.installation(user: user, account_login: "Acme")

      expect(described_class.find_for_owner("acme")).to eq(installation)
      expect(described_class.find_for_owner("ACME")).to eq(installation)
    end

    it "returns nil when the installation has been removed" do
      Factories.installation(user: user, account_login: "acme", removed_at: 1.day.ago)

      expect(described_class.find_for_owner("acme")).to be_nil
    end

    it "returns nil when no installation exists for the owner" do
      expect(described_class.find_for_owner("unknown-org")).to be_nil
    end
  end

  describe ".link_repositories_for" do
    it "sets installation_id on all repositories matching the installation's account_login" do
      installation = Factories.installation(user: user, account_login: "acme")
      repo1 = Factories.repository(user: user, owner: "acme")
      repo2 = Factories.repository(user: user, owner: "acme")
      other = Factories.repository(user: user, owner: "other-org")

      described_class.link_repositories_for(installation)

      expect(repo1.reload.installation).to eq(installation)
      expect(repo2.reload.installation).to eq(installation)
      expect(other.reload.installation).to be_nil
    end

    it "is case-insensitive when matching repository owner to account_login" do
      installation = Factories.installation(user: user, account_login: "Acme")
      repo = Factories.repository(user: user, owner: "acme")

      described_class.link_repositories_for(installation)

      expect(repo.reload.installation).to eq(installation)
    end
  end

  describe ".unlink_repositories_for" do
    it "clears installation_id from all repositories belonging to the installation" do
      installation = Factories.installation(user: user, account_login: "acme")
      repo1 = Factories.repository(user: user, owner: "acme", installation: installation)
      repo2 = Factories.repository(user: user, owner: "acme", installation: installation)
      other_installation = Factories.installation(user: user, account_login: "other-org")
      other_repo = Factories.repository(user: user, owner: "other-org", installation: other_installation)

      described_class.unlink_repositories_for(installation)

      expect(repo1.reload.installation).to be_nil
      expect(repo2.reload.installation).to be_nil
      expect(other_repo.reload.installation).to eq(other_installation)
    end
  end
end
