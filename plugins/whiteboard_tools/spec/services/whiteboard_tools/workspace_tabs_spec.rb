require "rails_helper"

RSpec.describe WhiteboardTools::WorkspaceTabs do
  describe ".workspace_tabs" do
    it "declares the whiteboard tab with a component key and id namespaced under whiteboard_tools" do
      tabs = described_class.workspace_tabs

      expect(tabs).to contain_exactly(
        include(
          id: "whiteboard_tools.canvas",
          component: "whiteboard_tools/WhiteboardTab",
          label_key: "whiteboard_tools:tab_whiteboard"
        )
      )
    end
  end

  describe ".available_for?" do
    it "is available in every chat, matching the tab's former unconditional presence in core" do
      chat_session = instance_double(ChatSession, repository: Factories.repository)

      expect(described_class.available_for?(chat_session)).to be(true)
    end

    it "is available even for a chat session with no repository" do
      chat_session = instance_double(ChatSession, repository: nil)

      expect(described_class.available_for?(chat_session)).to be(true)
    end
  end
end
