require "rails_helper"

RSpec.describe ChatProposal do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def proposal(slug)
    described_class.create!(
      chat_session: chat_session,
      slug: slug,
      title: "Proposal #{slug}",
      body: "Do #{slug}."
    )
  end

  it "creates a pending syrus issue proposal by default" do
    proposal = described_class.create!(
      chat_session: chat_session,
      slug: "roman-footer",
      title: "Roman footer",
      body: "Add a constitutionally proportionate Latin footer."
    )

    expect(proposal).to be_pending
    expect(proposal).to be_syrus_issue
  end

  it "validates required fields and enum values" do
    proposal = described_class.new(chat_session: chat_session, kind: "bogus", state: "lost")

    expect(proposal).not_to be_valid
    expect(proposal.errors[:slug]).to include("can't be blank")
    expect(proposal.errors[:title]).to include("can't be blank")
    expect(proposal.errors[:body]).to include("can't be blank")
    expect(proposal.errors[:kind]).to be_present
    expect(proposal.errors[:state]).to be_present
  end

  it "requires slugs to be unique within a chat session" do
    proposal("same")
    duplicate = described_class.new(
      chat_session: chat_session,
      slug: "same",
      title: "Duplicate",
      body: "This should not fit in the same session."
    )

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:slug]).to include("has already been taken")
  end

  it "allows the same slug in different chat sessions" do
    proposal("same")
    other_session = ChatSession.create!(user: user, repository: repository)

    duplicate_elsewhere = described_class.new(
      chat_session: other_session,
      slug: "same",
      title: "Duplicate elsewhere",
      body: "This is a different session."
    )

    expect(duplicate_elsewhere).to be_valid
  end

  describe ".topological_sort" do
    it "returns proposals in dependency order with roots first" do
      root = proposal("root")
      middle = proposal("middle")
      leaf = proposal("leaf")
      independent = proposal("independent")

      ChatProposalDependency.create!(proposal: middle, depends_on: root)
      ChatProposalDependency.create!(proposal: leaf, depends_on: middle)

      sorted = described_class.topological_sort(described_class.where(id: [ leaf.id, independent.id, middle.id, root.id ]))

      expect(sorted.index(root)).to be < sorted.index(middle)
      expect(sorted.index(middle)).to be < sorted.index(leaf)
      expect(sorted).to contain_exactly(root, middle, leaf, independent)
    end

    it "raises when the scoped proposals contain a cycle" do
      a = proposal("a")
      b = proposal("b")

      ChatProposalDependency.insert_all!([
        { proposal_id: a.id, depends_on_id: b.id, created_at: Time.current, updated_at: Time.current },
        { proposal_id: b.id, depends_on_id: a.id, created_at: Time.current, updated_at: Time.current }
      ])

      expect { described_class.topological_sort(described_class.where(id: [ a.id, b.id ])) }
        .to raise_error(ArgumentError, /cycle/)
    end
  end

  describe ".transitive_upstream_closure" do
    it "returns originals and all transitive dependencies" do
      root = proposal("root")
      middle = proposal("middle")
      leaf = proposal("leaf")
      unrelated = proposal("unrelated")

      ChatProposalDependency.create!(proposal: middle, depends_on: root)
      ChatProposalDependency.create!(proposal: leaf, depends_on: middle)

      expect(described_class.transitive_upstream_closure([ leaf ])).to contain_exactly(root, middle, leaf)
      expect(described_class.transitive_upstream_closure([ unrelated ])).to contain_exactly(unrelated)
    end
  end

  describe ".transitive_downstream_closure" do
    it "returns originals and all transitive dependents" do
      root = proposal("root")
      middle = proposal("middle")
      leaf = proposal("leaf")
      unrelated = proposal("unrelated")

      ChatProposalDependency.create!(proposal: middle, depends_on: root)
      ChatProposalDependency.create!(proposal: leaf, depends_on: middle)

      expect(described_class.transitive_downstream_closure([ root ])).to contain_exactly(root, middle, leaf)
      expect(described_class.transitive_downstream_closure([ unrelated ])).to contain_exactly(unrelated)
    end
  end
end
