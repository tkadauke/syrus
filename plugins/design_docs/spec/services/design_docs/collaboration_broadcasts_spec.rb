require "rails_helper"

RSpec.describe "Design Doc collaboration broadcasts" do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:collaborator) { Factories.user(email_address: "collaborator@example.com") }
  let(:doc) do
    DesignDoc.create!(owner_user: owner, title: "Live collaboration", markdown: "Alpha beta", visibility: "private").tap do |design_doc|
      version = design_doc.versions.create!(markdown: design_doc.markdown, version_number: 1, actor_kind: "user", actor_user: owner)
      design_doc.update!(current_version: version)
      design_doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    end
  end

  before { allow(DesignDocs::CommentBroadcaster).to receive(:call) }

  it "broadcasts accepted and rejected suggestion state after commit" do
    accepted = DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "gamma" }
    ).suggestion
    allow(DesignDocs::CommentBroadcaster).to receive(:call)

    DesignDocs::ReviewSuggestion.accept(suggestion: accepted, user: owner)
    expect(DesignDocs::CommentBroadcaster).to have_received(:call)
      .with(design_doc: doc, changed: [ "suggestions", "markdown" ])

    rejected = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload,
      user: collaborator,
      attributes: { start_offset: 0, end_offset: 5, original_markdown: "Alpha", proposed_markdown: "Omega" }
    ).suggestion
    expect(DesignDocs::CommentBroadcaster).to receive(:call)
      .with(design_doc: doc, changed: [ "suggestions" ])

    DesignDocs::ReviewSuggestion.reject(suggestion: rejected, user: owner)
  end

  it "broadcasts resolved discussion state after commit" do
    thread = DesignDocs::CreateComment.call(
      design_doc: doc,
      user: collaborator,
      attributes: { body: "Discuss this", start_offset: 0, end_offset: 5, selected_markdown: "Alpha" }
    ).thread
    transaction_depth = ActiveRecord::Base.connection.open_transactions

    expect(DesignDocs::CommentBroadcaster).to receive(:call) do |design_doc:, changed:|
      expect(design_doc).to eq(doc)
      expect(changed).to eq([ "threads" ])
      expect(ActiveRecord::Base.connection.open_transactions).to eq(transaction_depth)
    end

    DesignDocs::ResolveThread.call(thread: thread, user: owner)
  end

  it "scopes public document events to owners, collaborators, and attached repository members" do
    allow(DesignDocs::CommentBroadcaster).to receive(:call).and_call_original
    repository_member = Factories.user(email_address: "member@example.com")
    outsider = Factories.user(email_address: "outsider@example.com")
    repository = Factories.repository(user: owner, owner: "acme", name: "widgets")
    RepositoryMembership.create!(repository: repository, user: repository_member, role: "read")
    doc.update!(visibility: "public")
    doc.design_doc_repositories.create!(repository: repository)
    allow(AppEvents).to receive(:broadcast)

    DesignDocs::CommentBroadcaster.call(design_doc: doc, changed: [ "suggestions" ])

    [ owner, collaborator, repository_member ].each do |recipient|
      expect(AppEvents).to have_received(:broadcast).with(
        user: recipient,
        type: "design_doc.updated",
        resource: "design_doc",
        id: doc.id,
        changed: [ "suggestions" ]
      ).once
    end
    expect(AppEvents).not_to have_received(:broadcast).with(hash_including(user: outsider))
  end
end
