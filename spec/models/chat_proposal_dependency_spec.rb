require "rails_helper"

RSpec.describe ChatProposalDependency do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def proposal(slug)
    ChatProposal.create!(
      chat_session: chat_session,
      slug: slug,
      title: "Proposal #{slug}",
      body: "Do #{slug}."
    )
  end

  it "creates a dependency edge and exposes proposal associations" do
    root = proposal("root")
    leaf = proposal("leaf")

    described_class.create!(proposal: leaf, depends_on: root)

    expect(leaf.dependencies).to contain_exactly(root)
    expect(root.dependents).to contain_exactly(leaf)
  end

  it "rejects duplicate dependency edges" do
    root = proposal("root")
    leaf = proposal("leaf")
    described_class.create!(proposal: leaf, depends_on: root)

    duplicate = described_class.new(proposal: leaf, depends_on: root)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:depends_on_id]).to include("has already been taken")
  end

  it "rejects self references" do
    proposal = proposal("self")
    dependency = described_class.new(proposal: proposal, depends_on: proposal)

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on]).to include("can't be the same proposal")
  end

  it "rejects a direct cycle" do
    a = proposal("a")
    b = proposal("b")
    described_class.create!(proposal: a, depends_on: b)

    dependency = described_class.new(proposal: b, depends_on: a)

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on]).to include("would create a cycle")
  end

  it "rejects an indirect cycle" do
    a = proposal("a")
    b = proposal("b")
    c = proposal("c")
    described_class.create!(proposal: a, depends_on: b)
    described_class.create!(proposal: b, depends_on: c)

    dependency = described_class.new(proposal: c, depends_on: a)

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on]).to include("would create a cycle")
  end
end
