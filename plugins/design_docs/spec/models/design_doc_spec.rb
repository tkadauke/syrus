require "rails_helper"

RSpec.describe DesignDocs::DesignDoc, type: :model do
  let(:owner) { Factories.user }
  let(:repo) { Factories.repository(user: owner) }

  it "stores canonical markdown and exposes a DOC display id" do
    doc = described_class.create!(owner_user: owner, title: " Checkout design ", markdown: "# Checkout")

    expect(doc.title).to eq("Checkout design")
    expect(doc.markdown).to eq("# Checkout")
    expect(doc.visibility).to eq("private")
    expect(doc.state).to eq("draft")
    expect(doc.display_id).to eq("DOC-#{doc.id}")
    expect(doc.display_name).to eq("DOC-#{doc.id} Checkout design")
  end

  it "links to multiple repositories through a unique join model" do
    second_repo = Factories.repository(user: owner)
    doc = described_class.create!(owner_user: owner, title: "Architecture", markdown: "# Architecture")

    doc.repositories << repo
    doc.repositories << second_repo

    duplicate = DesignDocs::DesignDocRepository.new(design_doc: doc, repository: repo)

    expect(doc.repositories).to contain_exactly(repo, second_repo)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:repository_id]).to be_present
  end

  it "tracks explicit non-owner collaborators for private docs" do
    collaborator = Factories.user
    doc = described_class.create!(owner_user: owner, title: "Private plan", markdown: "# Private")

    membership = doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    owner_membership = doc.collaborators.build(user: owner, role: "viewer")

    expect(membership.user).to eq(collaborator)
    expect(owner_membership).not_to be_valid
    expect(owner_membership.errors[:user]).to include("is already the owner")
  end

  it "points at a current append-only version from the same document" do
    doc = described_class.create!(owner_user: owner, title: "Versioned", markdown: "v1")
    version = doc.versions.create!(markdown: "v1", version_number: 1, actor_kind: "user", actor_user: owner)
    other_doc = described_class.create!(owner_user: owner, title: "Other", markdown: "other")
    other_version = other_doc.versions.create!(markdown: "other", version_number: 1, actor_kind: "user", actor_user: owner)

    doc.update!(current_version: version)
    expect(doc.current_version).to eq(version)

    doc.current_version = other_version

    expect(doc).not_to be_valid
    expect(doc.errors[:current_version]).to include("must belong to this design doc")
  end

  it "can be destroyed after its current version is set" do
    doc = described_class.create!(owner_user: owner, title: "Destroyable", markdown: "v1")
    version = doc.versions.create!(markdown: "v1", version_number: 1, actor_kind: "user", actor_user: owner)
    doc.update!(current_version: version)

    expect {
      doc.destroy!
    }.to change(described_class, :count).by(-1)
      .and change(DesignDocs::DesignDocVersion, :count).by(-1)
  end

  it "validates visibility and state values" do
    doc = described_class.new(owner_user: owner, title: "Bad", markdown: "body", visibility: "team", state: "published")

    expect(doc).not_to be_valid
    expect(doc.errors[:visibility]).to be_present
    expect(doc.errors[:state]).to be_present
  end

  it "resolves v1 visibility from ownership, collaborators, and public repository access" do
    member = Factories.user
    outsider = Factories.user
    repo.repository_memberships.create!(user: member, role: "read")
    owned = described_class.create!(owner_user: owner, title: "Owned", markdown: "owned")
    private_doc = described_class.create!(owner_user: owner, title: "Private", markdown: "private")
    public_doc = described_class.create!(owner_user: owner, title: "Public", markdown: "public", visibility: "public")
    public_doc.repositories << repo
    private_doc.collaborators.create!(user: member, role: "viewer")

    expect(described_class.visible_to(owner)).to include(owned, private_doc, public_doc)
    expect(described_class.visible_to(member)).to include(private_doc, public_doc)
    expect(described_class.visible_to(member)).not_to include(owned)
    expect(described_class.visible_to(outsider)).to be_empty
  end
end
