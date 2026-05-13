require "rails_helper"

RSpec.describe "Repository proposals", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:session) { ChatSession.create!(repository: repo, user: user) }

  before { sign_in_as(user) }

  def proposal(slug:, title:, body: "Body for #{title}", state: "pending", chat_session: session, **attrs)
    ChatProposal.create!({
      chat_session: chat_session,
      slug: slug,
      title: title,
      body: body,
      state: state
    }.merge(attrs))
  end

  def depends_on(proposal, dependency)
    ChatProposalDependency.create!(proposal: proposal, depends_on: dependency)
  end

  describe "GET /repositories/:repository_id/proposals" do
    it "lists pending proposals and hides resolved proposals by default" do
      pending = proposal(slug: "pending-one", title: "Pending one")
      filed = proposal(slug: "filed-one", title: "Filed one", state: "filed", filed_at: Time.current)

      get repository_proposals_path(repo)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pending.title)
      expect(response.body).to include("Show recently filed/discarded")
      expect(response.body).not_to include(filed.title)
    end

    it "includes recently filed and discarded proposals when toggled" do
      filed = proposal(slug: "filed-one", title: "Filed one", state: "filed", filed_at: Time.current)
      discarded = proposal(slug: "discarded-one", title: "Discarded one", state: "discarded", discarded_at: Time.current)

      get repository_proposals_path(repo, include_resolved: "1")

      expect(response.body).to include(filed.title)
      expect(response.body).to include(discarded.title)
      expect(response.body).to include("Pending only")
    end

    it "renders the empty state when there are no pending proposals" do
      get repository_proposals_path(repo)

      expect(response.body).to include("No pending proposals. Open a chat to draft some.")
    end

    it "groups and orders proposals by DAG layer" do
      root = proposal(slug: "a", title: "Root A")
      middle = proposal(slug: "b", title: "Middle B")
      leaf = proposal(slug: "c", title: "Leaf C")
      sibling = proposal(slug: "d", title: "Sibling D")
      depends_on(middle, root)
      depends_on(leaf, middle)
      depends_on(sibling, root)

      get repository_proposals_path(repo)

      expect(response.body.index("Layer 1")).to be < response.body.index("Root A")
      expect(response.body.index("Root A")).to be < response.body.index("Layer 2")
      expect(response.body.index("Layer 2")).to be < response.body.index("Middle B")
      expect(response.body.index("Layer 2")).to be < response.body.index("Sibling D")
      expect(response.body.index("Middle B")).to be < response.body.index("Layer 3")
      expect(response.body.index("Layer 3")).to be < response.body.index("Leaf C")
      expect(response.body).to include("a")
      expect(response.body).to include("b")
    end
  end

  describe "PATCH /repositories/:repository_id/proposals/:id" do
    it "updates editable proposal fields" do
      draft = proposal(slug: "draft", title: "Draft", body: "Old body", labels: "bug")

      patch repository_proposal_path(repo, draft), params: {
        chat_proposal: { title: "Edited draft", body: "New body", labels: "enhancement, docs" }
      }

      expect(response).to redirect_to(repository_proposals_path(repo))
      expect(draft.reload.title).to eq("Edited draft")
      expect(draft.body).to eq("New body")
      expect(draft.labels).to eq("enhancement, docs")
    end

    it "re-renders the edit dialog on validation failure" do
      draft = proposal(slug: "draft", title: "Draft")

      patch repository_proposal_path(repo, draft), params: {
        chat_proposal: { title: "", body: "Still has a body", labels: "" }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Proposal could not be updated.")
      expect(response.body).to include("Title can")
      expect(draft.reload.title).to eq("Draft")
    end
  end

  describe "DELETE /repositories/:repository_id/proposals/:id" do
    it "discards only the selected proposal and removes it from dependents" do
      root = proposal(slug: "root", title: "Root")
      dependent = proposal(slug: "dependent", title: "Dependent")
      edge = depends_on(dependent, root)

      delete repository_proposal_path(repo, root), params: { discard_mode: "single" }

      expect(response).to redirect_to(repository_proposals_path(repo))
      expect(root.reload).to be_discarded
      expect(root.discarded_at).to be_present
      expect(dependent.reload).to be_pending
      expect(ChatProposalDependency.exists?(edge.id)).to be(false)
    end

    it "discards the downstream closure when cascading" do
      root = proposal(slug: "a", title: "Root A")
      middle = proposal(slug: "b", title: "Middle B")
      leaf = proposal(slug: "c", title: "Leaf C")
      sibling = proposal(slug: "d", title: "Sibling D")
      depends_on(middle, root)
      depends_on(leaf, middle)
      depends_on(sibling, root)

      delete repository_proposal_path(repo, root), params: { discard_mode: "cascade" }

      expect(response).to redirect_to(repository_proposals_path(repo))
      expect([ root, middle, leaf, sibling ].map { |p| p.reload.state }).to all(eq("discarded"))
      expect([ root, middle, leaf, sibling ].map(&:discarded_at)).to all(be_present)
    end
  end
end
