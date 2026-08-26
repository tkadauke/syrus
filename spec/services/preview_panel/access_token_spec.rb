require "rails_helper"

RSpec.describe PreviewPanel::AccessToken do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:panel) { PreviewPanel.create!(chat_session: chat_session, title: "Widget preview") }
  let(:other_panel) { PreviewPanel.create!(chat_session: chat_session, title: "Other preview") }

  describe ".issue / .panel_id_for" do
    it "issues a token that resolves back to the panel's id" do
      token = described_class.issue(panel)

      expect(described_class.panel_id_for(token)).to eq(panel.id)
    end

    it "does not resolve a token issued for a different panel" do
      token = described_class.issue(other_panel)

      expect(described_class.panel_id_for(token)).to eq(other_panel.id)
      expect(described_class.panel_id_for(token)).not_to eq(panel.id)
    end

    it "returns nil for a tampered token" do
      token = described_class.issue(panel)

      expect(described_class.panel_id_for("#{token}tampered")).to be_nil
    end

    it "returns nil for garbage input" do
      expect(described_class.panel_id_for("not-a-real-token")).to be_nil
    end

    it "returns nil for a blank token" do
      expect(described_class.panel_id_for(nil)).to be_nil
      expect(described_class.panel_id_for("")).to be_nil
    end

    it "is still valid just under the TTL" do
      token = nil
      freeze_time { token = described_class.issue(panel) }

      travel(described_class::TTL - 1.minute) do
        expect(described_class.panel_id_for(token)).to eq(panel.id)
      end
    end

    it "returns nil once the token has expired" do
      token = nil
      freeze_time { token = described_class.issue(panel) }

      travel(described_class::TTL + 1.minute) do
        expect(described_class.panel_id_for(token)).to be_nil
      end
    end
  end
end
