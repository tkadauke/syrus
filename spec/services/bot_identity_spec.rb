require "rails_helper"

RSpec.describe BotIdentity do
  describe ".github_handle" do
    it "uses the explicit GitHub handle when present" do
      user = Factories.user(github_handle: "octavia", email_address: "o@example.com")

      expect(described_class.github_handle(user)).to eq("octavia")
    end

    it "falls back to a sanitized email local-part" do
      user = Factories.user(github_handle: nil, email_address: "Tiberius+Ops@example.com")

      expect(described_class.github_handle(user)).to eq("tiberius-ops")
    end
  end

  describe ".human_name" do
    it "prefers name, then GitHub handle, then email local-part" do
      named = Factories.user(name: "Tiberius Claudius", github_handle: "claudius")
      handled = Factories.user(name: nil, github_handle: "octavia", email_address: "octavia@example.com")
      emailed = Factories.user(name: nil, github_handle: nil, email_address: "brutus@example.com")

      expect(described_class.human_name(named)).to eq("Tiberius Claudius")
      expect(described_class.human_name(handled)).to eq("octavia")
      expect(described_class.human_name(emailed)).to eq("brutus")
    end
  end

  describe ".prefix_comment" do
    it "prefixes comments with the represented GitHub handle" do
      user = Factories.user(github_handle: "lucius")

      expect(described_class.prefix_comment("Ship it.", on_behalf_of: user))
        .to eq("Syrus on behalf of @lucius\n\nShip it.")
    end

    it "returns the original body when no handle can be derived" do
      user = Factories.user(github_handle: nil, email_address: "@@@@")

      expect(described_class.prefix_comment("Ship it.", on_behalf_of: user)).to eq("Ship it.")
      expect(described_class.prefix_comment("Ship it.")).to eq("Ship it.")
    end
  end

  describe "git author identity" do
    it "uses the GitHub App bot identity when the app is registered and the repository has an active installation" do
      AppSetting.current.update!(github_app_id: 123, github_app_slug: "tkadauke-syrus")
      user = Factories.user(name: "Human Operator", email_address: "human@example.com")
      installation = Factories.installation(user: user, account_login: "acme")
      repository = Factories.repository(user: user, owner: "acme", installation: installation)
      job = Factories.job(repository: repository)

      identity = described_class.for(job)

      expect(identity.git_name).to eq("tkadauke-syrus[bot]")
      expect(identity.git_email).to eq("tkadauke-syrus[bot]@users.noreply.github.com")
    end

    it "falls back to the human identity when the app is not registered or the installation is inactive" do
      AppSetting.current.update!(github_app_id: nil, github_app_slug: "tkadauke-syrus")
      user = Factories.user(name: "Human Operator", email_address: "human@example.com")
      installation = Factories.installation(user: user, account_login: "acme", removed_at: Time.current)
      repository = Factories.repository(user: user, owner: "acme", installation: installation)
      job = Factories.job(repository: repository)

      identity = described_class.for(job)

      expect(identity.git_name).to eq("Human Operator")
      expect(identity.git_email).to eq("human@example.com")
    end
  end

  describe "#append_co_authored_by" do
    it "appends the human co-author trailer once for issue jobs" do
      user = Factories.user(name: "Human Operator", email_address: "human@example.com")
      job = Factories.job(repository: Factories.repository(user: user))
      identity = described_class.for(job)

      message = identity.append_co_authored_by("Implement the thing\n")

      expect(message).to eq("Implement the thing\n\nCo-Authored-By: Human Operator <human@example.com>")
      expect(identity.append_co_authored_by(message).scan("Co-Authored-By:").size).to eq(1)
    end
  end
end
