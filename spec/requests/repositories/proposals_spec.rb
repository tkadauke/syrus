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

    it "shows filed proposal Job links only when resolved proposals are included" do
      job = Job.create!(user: user, repository: repo, kind: "adhoc", issue_title: "Filed", issue_body: "Filed body")
      filed = proposal(slug: "filed-one", title: "Filed one", state: "filed", job: job, filed_at: Time.current)

      get repository_proposals_path(repo)
      expect(response.body).not_to include(filed.title)

      get repository_proposals_path(repo, include_resolved: "1")
      expect(response.body).to include("Filed as Job ##{job.id}")
      expect(response.body).to include(job_path(job))
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

  describe "GET /repositories/:repository_id/proposals/:id/file" do
    it "renders a cascade review modal for a single proposal" do
      root = proposal(slug: "root", title: "Root", body: "Root body")
      leaf = proposal(slug: "leaf", title: "Leaf", body: "Leaf body")
      depends_on(leaf, root)

      get file_repository_proposal_path(repo, leaf)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("File proposals")
      expect(response.body.index("Root")).to be < response.body.index("Leaf")
      expect(response.body).to include("Root body")
      expect(response.body).to include("Leaf body")
      expect(response.body).to include("Confirm filing")
    end
  end

  describe "POST /repositories/:repository_id/proposals/:id/file" do
    it "files one proposal with its upstream closure" do
      root = proposal(slug: "root", title: "Root")
      leaf = proposal(slug: "leaf", title: "Leaf")
      depends_on(leaf, root)

      expect {
        post file_repository_proposal_path(repo, leaf)
      }.to change(Job, :count).by(2)
        .and change(JobDependency, :count).by(1)

      expect(response).to redirect_to(repository_proposals_path(repo))
      expect(root.reload).to be_filed
      expect(leaf.reload).to be_filed
      expect(leaf.job.dependencies.first.depends_on_job).to eq(root.job)
    end
  end

  describe "GET /repositories/:repository_id/proposals/file_bulk" do
    it "renders a cascade review modal for selected proposals" do
      root = proposal(slug: "root", title: "Root")
      left = proposal(slug: "left", title: "Left")
      right = proposal(slug: "right", title: "Right")
      depends_on(left, root)
      depends_on(right, root)

      get file_bulk_repository_proposals_path(repo, proposal_ids: [ left.id, right.id ])

      expect(response).to have_http_status(:ok)
      expect(response.body.scan("Root").size).to be >= 1
      expect(response.body).to include("Left")
      expect(response.body).to include("Right")
      expect(response.body).to include("proposal_ids")
    end
  end

  describe "POST /repositories/:repository_id/proposals/file_bulk" do
    it "files selected proposals and dedupes shared upstream proposals" do
      root = proposal(slug: "root", title: "Root")
      left = proposal(slug: "left", title: "Left")
      right = proposal(slug: "right", title: "Right")
      depends_on(left, root)
      depends_on(right, root)

      expect {
        post file_bulk_repository_proposals_path(repo), params: { proposal_ids: [ left.id, right.id ] }
      }.to change(Job, :count).by(3)
        .and change(JobDependency, :count).by(2)

      expect(response).to redirect_to(repository_proposals_path(repo))
      expect([ root, left, right ].map { |p| p.reload.state }).to all(eq("filed"))
    end

    it "files all pending proposals" do
      first = proposal(slug: "first", title: "First")
      second = proposal(slug: "second", title: "Second")

      expect {
        post file_bulk_repository_proposals_path(repo), params: { all: "1" }
      }.to change(Job, :count).by(2)

      expect(first.reload).to be_filed
      expect(second.reload).to be_filed
    end
  end
end
