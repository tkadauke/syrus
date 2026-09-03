require "rails_helper"

RSpec.describe DesignDocs::DataCleanup do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def create_doc(**attrs)
    DesignDocs::DesignDoc.create!({ owner_user: user, title: "Spec doc", markdown: "# Spec doc" }.merge(attrs))
  end

  it "removes a user's documents when the user is destroyed" do
    create_doc

    expect { user.destroy! }.to change(DesignDocs::DesignDoc, :count).by(-1)
  end

  it "removes a repository's document links when the repository is destroyed" do
    doc = create_doc
    DesignDocs::DesignDocRepository.create!(design_doc: doc, repository: repository)

    expect { repository.destroy! }.to change(DesignDocs::DesignDocRepository, :count).by(-1)
    expect(doc.reload).to be_persisted
  end

  # The injected association was dependent: :nullify, not :destroy — a document
  # that happened to originate in a chat outlives that chat.
  it "nullifies the origin chat reference instead of destroying the document" do
    chat = ChatSession.create!(user: user)
    doc = create_doc(origin_chat_session: chat)

    expect { chat.destroy! }.not_to change(DesignDocs::DesignDoc, :count)
    expect(doc.reload.origin_chat_session_id).to be_nil
  end

  it "no longer declares associations on core models" do
    expect(User.reflect_on_association(:owned_design_docs)).to be_nil
    expect(Repository.reflect_on_association(:design_doc_repositories)).to be_nil
    expect(ChatSession.reflect_on_association(:originated_design_docs)).to be_nil
  end
end
