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

  it "is available and exposes payload data when the chat has an originated visible design doc" do
    doc = DesignDoc.create!(owner_user: user, origin_chat_session: chat_session, title: "Plan", markdown: "Body", visibility: "private")

    expect(described_class.available_for?(chat_session)).to be(true)
    expect(described_class.workspace_tabs(chat_session).first.fetch(:data)).to include(
      design_doc_ids: [ doc.id ],
      originated_design_doc_ids: [ doc.id ],
      attached_design_doc_ids: [],
      design_docs: [ include(id: doc.id, display_id: doc.display_id, title: "Plan") ]
    )
  end

  it "is available for visible DOC references mentioned in chat messages" do
    doc = DesignDoc.create!(owner_user: user, title: "Referenced", markdown: "Body", visibility: "private")
    chat_session.messages.create!(role: "user", content: { "text" => "Discuss #{doc.display_id}" })

    expect(described_class.available_for?(chat_session)).to be(true)
    expect(described_class.workspace_tabs(chat_session).first.dig(:data, :attached_design_doc_ids)).to eq([ doc.id ])
  end

  it "does not parse unrelated chat messages while looking for DOC references" do
    doc = DesignDoc.create!(owner_user: user, title: "Referenced", markdown: "Body", visibility: "private")
    chat_session.messages.create!(role: "user", content: { "text" => "A large message without references" })
    chat_session.messages.create!(role: "assistant", content: [ { "type" => "text", "text" => "Discuss #{doc.display_id}" } ])

    allow(described_class).to receive(:extract_doc_refs).and_call_original

    expect(described_class.referenced_design_doc_ids(chat_session)).to eq([ doc.id ])
    expect(described_class).not_to have_received(:extract_doc_refs).with({ "text" => "A large message without references" })
    expect(described_class).to have_received(:extract_doc_refs).with([ { "type" => "text", "text" => "Discuss #{doc.display_id}" } ])
  end

  it "is hidden when the chat has no visible design docs" do
    expect(described_class.available_for?(chat_session)).to be(false)
  end
end
