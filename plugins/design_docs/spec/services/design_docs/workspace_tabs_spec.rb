require "rails_helper"

RSpec.describe DesignDocs::WorkspaceTabs do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, title: "Design chat") }

  it "declares a closeable chat workspace tab" do
    expect(described_class.workspace_tabs).to contain_exactly(
      include(
        id: "design_docs.chat",
        label: "Design Docs",
        component: "design_docs/WorkspaceDesignDocs",
        closable: true
      )
    )
  end

  it "is available when the chat has an originated visible design doc" do
    DesignDoc.create!(owner_user: user, origin_chat_session: chat_session, title: "Plan", markdown: "Body", visibility: "private")

    expect(described_class.available_for?(chat_session)).to be(true)
  end

  it "is hidden when the chat has no visible design docs" do
    expect(described_class.available_for?(chat_session)).to be(false)
  end
end
