require "rails_helper"

RSpec.describe "GET /api/v1/app/chats/:chat_id/job_status", type: :request do
  let(:user)         { Factories.user }
  let(:repository)   { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user) }

  def parse_body
    JSON.parse(response.body)
  end

  it "returns 401 when not signed in" do
    get "/api/v1/app/chats/#{chat_session.id}/job_status"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 404 when the chat belongs to another user" do
    sign_in_as(user)
    other_chat = ChatSession.create!(user: Factories.user)

    get "/api/v1/app/chats/#{other_chat.id}/job_status"

    expect(response).to have_http_status(:not_found)
  end

  context "when signed in" do
    before { sign_in_as(user) }

    it "returns an empty array when the chat has no confirmed proposals" do
      ChatProposal.create!(
        chat_session: chat_session, slug: "pending-job", kind: "job",
        title: "A pending job", body: "Not yet filed.", state: "proposed"
      )

      get "/api/v1/app/chats/#{chat_session.id}/job_status"

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq([])
    end

    it "excludes confirmed proposals with no materialized job or epic" do
      ChatProposal.create!(
        chat_session: chat_session, slug: "ghost", kind: "job",
        title: "Ghost proposal", body: "No job linked.", state: "confirmed"
      )

      get "/api/v1/app/chats/#{chat_session.id}/job_status"

      expect(parse_body).to eq([])
    end

    describe "job items" do
      it "returns core job fields for a confirmed job proposal" do
        job = Factories.job_record(
          user: user, repository: repository, state: "running", issue_title: "Refactor auth"
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "refactor-auth", kind: "job",
          title: "Refactor auth", body: "Clean it up.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(response).to have_http_status(:ok)
        item = parse_body.first
        expect(item["kind"]).to eq("job")
        expect(item["job_id"]).to eq(job.id)
        expect(item["slug"]).to eq(job.slug)
        expect(item["title"]).to eq("Refactor auth")
        expect(item["state"]).to eq("running")
        expect(item["workflow_step"]).to be_nil
        expect(item["pr_number"]).to be_nil
        expect(item["pr_url"]).to be_nil
        expect(item["blocker"]).to be_nil
        expect(item["updated_at"]).to eq(job.updated_at.iso8601)
      end

      it "includes pr_number and pr_url when the job has an open PR" do
        job = Factories.job_record(
          user: user, repository: repository, state: "implemented",
          issue_title: "Add feature", pr_number: 42, approved_at: Time.current
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "add-feature", kind: "job",
          title: "Add feature", body: "Build it.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        item = parse_body.first
        expect(item["pr_number"]).to eq(42)
        expect(item["pr_url"]).to eq("https://github.com/acme/widgets/pull/42")
      end

      it "sets workflow_step to the current step kind when a workflow is running" do
        job = Factories.job_record(
          user: user, repository: repository, state: "running", issue_title: "Impl"
        )
        workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
        Step.create!(workflow: workflow, kind: "implement", position: 0, state: "running")

        ChatProposal.create!(
          chat_session: chat_session, slug: "impl-job", kind: "job",
          title: "Impl", body: "Implement it.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(parse_body.first["workflow_step"]).to eq("implement")
      end

      it "falls back to trigger_kind as workflow_step when no current step is found" do
        job = Factories.job_record(
          user: user, repository: repository, state: "running", issue_title: "Summarize"
        )
        Workflow.create!(job: job, trigger_kind: "retry", state: "running")

        ChatProposal.create!(
          chat_session: chat_session, slug: "retry-job", kind: "job",
          title: "Summarize", body: "Retry run.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(parse_body.first["workflow_step"]).to eq("retry")
      end
    end

    describe "blocker detection" do
      it "returns awaiting_review when job is implemented and not yet approved" do
        job = Factories.job_record(
          user: user, repository: repository, state: "implemented", issue_title: "Needs review"
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "needs-review", kind: "job",
          title: "Needs review", body: "Review me.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        blocker = parse_body.first["blocker"]
        expect(blocker["reason"]).to eq("awaiting_review")
      end

      it "returns no blocker when implemented and already approved" do
        job = Factories.job_record(
          user: user, repository: repository, state: "implemented",
          issue_title: "Already approved", approved_at: Time.current
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "approved-job", kind: "job",
          title: "Already approved", body: "Approved.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(parse_body.first["blocker"]).to be_nil
      end

      it "returns landing_failed when approved and the latest auto_merge workflow failed" do
        job = Factories.job_record(
          user: user, repository: repository, state: "approved", issue_title: "Landing failed"
        )
        Workflow.create!(job: job, trigger_kind: "auto_merge", state: "failed")

        ChatProposal.create!(
          chat_session: chat_session, slug: "landing-failed", kind: "job",
          title: "Landing failed", body: "Stuck.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(parse_body.first.dig("blocker", "reason")).to eq("landing_failed")
      end

      it "returns landing_failed when landing state and the latest auto_merge workflow failed" do
        job = Factories.job_record(
          user: user, repository: repository, state: "landing", issue_title: "Still landing"
        )
        Workflow.create!(job: job, trigger_kind: "auto_merge", state: "failed")

        ChatProposal.create!(
          chat_session: chat_session, slug: "still-landing", kind: "job",
          title: "Still landing", body: "In queue.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(parse_body.first.dig("blocker", "reason")).to eq("landing_failed")
      end

      it "returns no blocker when the latest auto_merge workflow succeeded" do
        job = Factories.job_record(
          user: user, repository: repository, state: "approved", issue_title: "Merged soon"
        )
        Workflow.create!(job: job, trigger_kind: "auto_merge", state: "succeeded")

        ChatProposal.create!(
          chat_session: chat_session, slug: "merged-soon", kind: "job",
          title: "Merged soon", body: "Almost.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(parse_body.first["blocker"]).to be_nil
      end

      it "returns dependency_failed when queued and a dependency job has a failure closure reason" do
        dep_job = Factories.job_record(
          user: user, repository: repository, state: "closed",
          closure_reason: "too_many_failures", issue_title: "Failed dep"
        )
        job = Factories.job_record(
          user: user, repository: repository, state: "queued", issue_title: "Blocked job"
        )
        JobDependency.create!(job: job, depends_on_job: dep_job, source: "manual")

        ChatProposal.create!(
          chat_session: chat_session, slug: "blocked-job", kind: "job",
          title: "Blocked job", body: "Waiting.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(parse_body.first.dig("blocker", "reason")).to eq("dependency_failed")
      end

      it "returns no blocker when a dependency closed successfully" do
        dep_job = Factories.job_record(
          user: user, repository: repository, state: "closed",
          closure_reason: "pr_merged", issue_title: "Merged dep"
        )
        job = Factories.job_record(
          user: user, repository: repository, state: "queued", issue_title: "Ready job"
        )
        JobDependency.create!(job: job, depends_on_job: dep_job, source: "manual")

        ChatProposal.create!(
          chat_session: chat_session, slug: "ready-job", kind: "job",
          title: "Ready job", body: "Dep merged.", state: "confirmed",
          job: job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(parse_body.first["blocker"]).to be_nil
      end
    end

    describe "epic items" do
      it "returns an epic item with progress, nested child job items, and latest_updated_at" do
        epic = Factories.epic(user: user, repository: repository, title: "Big refactor")

        done_job = Factories.job_record(
          user: user, repository: repository, state: "closed",
          closure_reason: "pr_merged", issue_title: "Part A"
        )
        open_job = Factories.job_record(
          user: user, repository: repository, state: "running", issue_title: "Part B"
        )

        epic_proposal = ChatProposal.create!(
          chat_session: chat_session, slug: "big-refactor", kind: "epic",
          title: "Big refactor", body: "Refactor everything.", state: "confirmed",
          epic: epic, repository: repository
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "part-a", kind: "job",
          title: "Part A", body: "First part.", state: "confirmed",
          job: done_job, repository: repository, parent_proposal: epic_proposal
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "part-b", kind: "job",
          title: "Part B", body: "Second part.", state: "confirmed",
          job: open_job, repository: repository, parent_proposal: epic_proposal
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(response).to have_http_status(:ok)
        items = parse_body
        expect(items.size).to eq(1)

        epic_item = items.first
        expect(epic_item["kind"]).to eq("epic")
        expect(epic_item["epic_id"]).to eq(epic.id)
        expect(epic_item["slug"]).to eq(epic.slug)
        expect(epic_item["title"]).to eq("Big refactor")
        expect(epic_item["state"]).to eq("backlog")
        expect(epic_item.dig("progress", "done")).to eq(1)
        expect(epic_item.dig("progress", "total")).to eq(2)
        expect(epic_item["latest_updated_at"]).to be_present

        children = epic_item["children"]
        expect(children.size).to eq(2)
        expect(children).to all(include("kind" => "job"))
        child_slugs = children.map { |c| c["slug"] }
        expect(child_slugs).to contain_exactly(done_job.slug, open_job.slug)
        expect(children).to all(include("updated_at"))
      end

      it "places job proposals without an epic parent as standalone items" do
        epic = Factories.epic(user: user, repository: repository, title: "My epic")
        child_job    = Factories.job_record(user: user, repository: repository, state: "queued", issue_title: "Child")
        sibling_job  = Factories.job_record(user: user, repository: repository, state: "queued", issue_title: "Sibling")

        epic_proposal = ChatProposal.create!(
          chat_session: chat_session, slug: "my-epic", kind: "epic",
          title: "My epic", body: "Epic.", state: "confirmed",
          epic: epic, repository: repository
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "child-job", kind: "job",
          title: "Child", body: "In epic.", state: "confirmed",
          job: child_job, repository: repository, parent_proposal: epic_proposal
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "sibling-job", kind: "job",
          title: "Sibling", body: "No parent.", state: "confirmed",
          job: sibling_job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        items = parse_body
        expect(items.size).to eq(2)

        epic_item      = items.find { |i| i["kind"] == "epic" }
        standalone_item = items.find { |i| i["kind"] == "job" }

        expect(epic_item["children"].size).to eq(1)
        expect(standalone_item["slug"]).to eq(sibling_job.slug)
      end

      it "omits epic proposals with no materialized epic" do
        ChatProposal.create!(
          chat_session: chat_session, slug: "ghost-epic", kind: "epic",
          title: "Ghost epic", body: "Never filed.", state: "confirmed"
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        expect(parse_body).to eq([])
      end
    end

    describe "sort order" do
      it "returns standalone jobs sorted by updated_at desc" do
        older_job = Factories.job_record(user: user, repository: repository, state: "running", issue_title: "Older")
        newer_job = Factories.job_record(user: user, repository: repository, state: "running", issue_title: "Newer")

        older_job.update_column(:updated_at, 2.hours.ago)
        newer_job.update_column(:updated_at, 1.hour.ago)

        ChatProposal.create!(
          chat_session: chat_session, slug: "older-job", kind: "job",
          title: "Older", body: "Old.", state: "confirmed",
          job: older_job, repository: repository
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "newer-job", kind: "job",
          title: "Newer", body: "New.", state: "confirmed",
          job: newer_job, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        items = parse_body
        expect(items.map { |i| i["slug"] }).to eq([ newer_job.slug, older_job.slug ])
      end

      it "returns epic children sorted by updated_at desc" do
        epic = Factories.epic(user: user, repository: repository, title: "Sort epic")

        older_child = Factories.job_record(user: user, repository: repository, state: "running", issue_title: "Older child")
        newer_child = Factories.job_record(user: user, repository: repository, state: "running", issue_title: "Newer child")

        older_child.update_column(:updated_at, 2.hours.ago)
        newer_child.update_column(:updated_at, 1.hour.ago)

        epic_proposal = ChatProposal.create!(
          chat_session: chat_session, slug: "sort-epic", kind: "epic",
          title: "Sort epic", body: "Sort.", state: "confirmed",
          epic: epic, repository: repository
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "older-child", kind: "job",
          title: "Older child", body: "Old.", state: "confirmed",
          job: older_child, repository: repository, parent_proposal: epic_proposal
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "newer-child", kind: "job",
          title: "Newer child", body: "New.", state: "confirmed",
          job: newer_child, repository: repository, parent_proposal: epic_proposal
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        children = parse_body.first["children"]
        expect(children.map { |c| c["slug"] }).to eq([ newer_child.slug, older_child.slug ])
      end

      it "interleaves epics and standalone jobs by updated_at desc" do
        standalone = Factories.job_record(user: user, repository: repository, state: "running", issue_title: "Standalone")
        child_job  = Factories.job_record(user: user, repository: repository, state: "running", issue_title: "Child")
        epic       = Factories.epic(user: user, repository: repository, title: "My epic")

        standalone.update_column(:updated_at, 1.hour.ago)
        child_job.update_column(:updated_at, 3.hours.ago)

        epic_proposal = ChatProposal.create!(
          chat_session: chat_session, slug: "my-epic", kind: "epic",
          title: "My epic", body: "Epic.", state: "confirmed",
          epic: epic, repository: repository
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "child-job", kind: "job",
          title: "Child", body: "Child.", state: "confirmed",
          job: child_job, repository: repository, parent_proposal: epic_proposal
        )
        ChatProposal.create!(
          chat_session: chat_session, slug: "standalone-job", kind: "job",
          title: "Standalone", body: "Alone.", state: "confirmed",
          job: standalone, repository: repository
        )

        get "/api/v1/app/chats/#{chat_session.id}/job_status"

        items = parse_body
        expect(items.size).to eq(2)
        # standalone updated 1 hour ago, epic's latest child updated 3 hours ago
        expect(items.first["kind"]).to eq("job")
        expect(items.first["slug"]).to eq(standalone.slug)
        expect(items.last["kind"]).to eq("epic")
      end
    end
  end
end
