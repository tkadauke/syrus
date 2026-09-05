require "rails_helper"

RSpec.describe Mockups::Mockup do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user, title: "Planning") }
  let(:panel) { PreviewPanel::Service.open!(chat_session: chat, title: "Sketch", files: { "index.html" => "<h1>hi</h1>" }) }

  it "slugs by id, the way JOB- and EPIC- do" do
    expect(described_class.new(id: 12).slug).to eq("MOCKUP-12")
  end

  describe ".id_from_ref" do
    it "accepts a bare id and a prefixed slug, case-insensitively" do
      expect(described_class.id_from_ref("7")).to eq(7)
      expect(described_class.id_from_ref("MOCKUP-7")).to eq(7)
      expect(described_class.id_from_ref("mockup-7")).to eq(7)
    end

    it "rejects anything else rather than guessing" do
      expect(described_class.id_from_ref("EPIC-7")).to be_nil
      expect(described_class.id_from_ref("MOCKUP-")).to be_nil
      expect(described_class.id_from_ref(nil)).to be_nil
    end
  end

  describe ".record_publish!" do
    it "records the panel as a mockup" do
      mockup = described_class.record_publish!(panel: panel, user: user, title: "Sketch", chat_session: chat)

      expect(mockup).to have_attributes(preview_panel_id: panel.id, user_id: user.id, title: "Sketch")
      expect(mockup.published_at).to be_present
    end

    # Republishing is how an agent iterates, so the slug has to survive it --
    # otherwise every edit would hand the operator a new identifier.
    it "updates the same row on republish, keeping the slug stable" do
      first = described_class.record_publish!(panel: panel, user: user, title: "Sketch", chat_session: chat)
      second = described_class.record_publish!(panel: panel, user: user, title: "Sketch v2", chat_session: chat)

      expect(second.id).to eq(first.id)
      expect(second.slug).to eq(first.slug)
      expect(second.title).to eq("Sketch v2")
      expect(described_class.where(preview_panel_id: panel.id).count).to eq(1)
    end

    it "falls back to a title rather than failing validation on a blank one" do
      mockup = described_class.record_publish!(panel: panel, user: user, title: "  ", chat_session: chat)

      expect(mockup.title).to eq("Untitled mockup")
    end
  end
end
