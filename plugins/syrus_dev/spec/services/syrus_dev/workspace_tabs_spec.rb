require "rails_helper"

RSpec.describe SyrusDev::WorkspaceTabs do
  describe ".workspace_tabs" do
    it "declares the demo tab with a component key and id namespaced under syrus_dev" do
      tabs = described_class.workspace_tabs

      expect(tabs).to contain_exactly(
        include(
          id: "syrus_dev.workspace_tab_demo",
          component: "syrus_dev/WorkspaceTabDemo",
          label_key: "syrus_dev:workspace_tab_demo_label"
        )
      )
    end
  end

  describe ".available_for?" do
    it "is available when the chat session has a repository" do
      chat_session = instance_double(ChatSession, repository: Factories.repository)

      expect(described_class.available_for?(chat_session)).to be(true)
    end

    it "is unavailable when the chat session has no repository" do
      chat_session = instance_double(ChatSession, repository: nil)

      expect(described_class.available_for?(chat_session)).to be(false)
    end
  end
end
