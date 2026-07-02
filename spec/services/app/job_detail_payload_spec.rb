require "rails_helper"

RSpec.describe App::JobDetailPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    described_class.build(job: job, user: user)
  end

  describe "#job_json" do
    it "links a chat-created Job back to the proposal message" do
      chat = ChatSession.create!(user: user, repository: repo, title: "Release planning")
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Map auth")
      proposal = chat.proposals.create!(
        slug: "map-auth",
        title: "Map auth",
        body: "Trace the auth flow.",
        job: job,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal proposed." })

      expect(payload_for(job).dig(:job, :source_chat)).to include(
        chat_id: chat.id,
        chat_title: "Release planning",
        proposal_id: proposal.id,
        proposal_kind: "syrus_issue",
        message_id: message.id,
        path: "/chats/#{chat.id}#message-#{message.id}",
        label: "Job proposal in Release planning"
      )
    end

    it "falls back to the Job Epic's proposal when the Job has no direct proposal" do
      chat = ChatSession.create!(user: user, repository: repo)
      epic = Factories.epic(user: user, repository: repo, title: "Auth")
      job = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 7)
      proposal = chat.proposals.create!(
        slug: "auth",
        title: "Auth",
        body: "Group auth work.",
        kind: "epic",
        epic: epic,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Epic proposed." })

      expect(payload_for(job).dig(:job, :source_chat)).to include(
        chat_id: chat.id,
        proposal_id: proposal.id,
        proposal_kind: "epic",
        message_id: message.id,
        path: "/chats/#{chat.id}#message-#{message.id}",
        label: "Epic proposal"
      )
    end
  end

  describe "#origin_chat_json" do
    it "returns the originating chat session and message for a directly proposed job" do
      chat = ChatSession.create!(user: user, repository: repo, title: "Release planning")
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Map auth")
      proposal = chat.proposals.create!(
        slug: "map-auth",
        title: "Map auth",
        body: "Trace the auth flow.",
        job: job,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal proposed." })

      expect(payload_for(job)[:origin_chat]).to eq(
        chat_session_id: chat.id,
        message_id: message.id
      )
    end

    it "falls back to the job epic's proposal when the job has no direct proposal" do
      chat = ChatSession.create!(user: user, repository: repo)
      epic = Factories.epic(user: user, repository: repo, title: "Auth")
      job = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 7)
      proposal = chat.proposals.create!(
        slug: "auth",
        title: "Auth",
        body: "Group auth work.",
        kind: "epic",
        epic: epic,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )
      message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Epic proposed." })

      expect(payload_for(job)[:origin_chat]).to eq(
        chat_session_id: chat.id,
        message_id: message.id
      )
    end

    it "returns nil when neither the job nor its epic has a chat proposal" do
      epic = Factories.epic(user: user, repository: repo, title: "Auth")
      job = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 7)

      expect(payload_for(job)[:origin_chat]).to be_nil
    end

    it "returns nil when a proposal exists without a linked chat message" do
      chat = ChatSession.create!(user: user, repository: repo)
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Map auth")
      chat.proposals.create!(
        slug: "map-auth",
        title: "Map auth",
        body: "Trace the auth flow.",
        job: job,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )

      expect(payload_for(job)[:origin_chat]).to be_nil
    end
  end

  describe "#test_plan_json" do
    it "returns nil when the job has no workflows" do
      job = Factories.job_record(repository: repo)

      expect(payload_for(job)[:test_plan]).to be_nil
    end

    it "returns the test plan artifact in a stable top-level shape" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: {
          "test_plan" => {
            "steps" => [ "Run bin/rspec spec/services/app/job_detail_payload_spec.rb", "Run bin/test-react" ],
            "notes" => "Check the Summary tab."
          }
        }
      )

      expect(payload_for(job)[:test_plan]).to eq(
        workflow_id: workflow.id,
        steps: [ "Run bin/rspec spec/services/app/job_detail_payload_spec.rb", "Run bin/test-react" ],
        notes: "Check the Summary tab."
      )
    end

    it "picks the latest workflow with a test plan artifact" do
      job = Factories.job_record(repository: repo)
      older = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        created_at: 2.hours.ago,
        artifacts: { "test_plan" => { "steps" => [ "Run old tests" ], "notes" => "old" } }
      )
      newer = Workflow.create!(
        job: job,
        trigger_kind: "retry",
        state: "succeeded",
        created_at: 1.hour.ago,
        artifacts: { "test_plan" => { "steps" => [ "Run new tests" ], "notes" => nil } }
      )

      expect(payload_for(job)[:test_plan]).to include(
        workflow_id: newer.id,
        steps: [ "Run new tests" ],
        notes: nil
      )
      expect(payload_for(job)[:test_plan][:workflow_id]).not_to eq(older.id)
    end

    it "treats a workflow with empty steps as absent" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        artifacts: { "test_plan" => { "steps" => [], "notes" => "Nothing to run." } }
      )

      expect(payload_for(job)[:test_plan]).to be_nil
    end

    it "ignores unfinished and non initial/retry workflow test plans" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "running",
        created_at: 1.hour.ago,
        artifacts: { "test_plan" => { "steps" => [ "Run unfinished tests" ], "notes" => nil } }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        created_at: 30.minutes.ago,
        artifacts: { "test_plan" => { "steps" => [ "Run follow-up tests" ], "notes" => nil } }
      )

      expect(payload_for(job)[:test_plan]).to be_nil
    end
  end

  describe "#feedback_history_json" do
    it "returns chat feedback workflow artifacts in chronological order" do
      job = Factories.job_record(repository: repo)
      newer = Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "running",
        created_at: 1.hour.ago,
        artifacts: { "chat_feedback" => "New feedback" }
      )
      older = Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "succeeded",
        created_at: 2.hours.ago,
        artifacts: { "chat_feedback" => "Old feedback" }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        created_at: 3.hours.ago,
        artifacts: { "chat_feedback" => "PR feedback artifact" }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "failed",
        created_at: 30.minutes.ago,
        artifacts: { "chat_feedback" => "" }
      )

      expect(payload_for(job)[:feedback_history]).to eq(
        [
          { kind: "chat_feedback", body: "Old feedback", created_at: older.created_at.iso8601, state: "succeeded" },
          { kind: "chat_feedback", body: "New feedback", created_at: newer.created_at.iso8601, state: "running" }
        ]
      )
    end

    it "returns PR comment workflow artifacts with author attribution" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        created_at: 1.hour.ago,
        artifacts: {
          "pr_comments" => [
            { "author" => "alice", "body" => "Please cover the blank state." },
            { "author" => "bob", "body" => "This should mention review feedback." }
          ]
        }
      )

      expect(payload_for(job)[:feedback_history]).to eq(
        [
          {
            kind: "pr_comment",
            body: "@alice: Please cover the blank state.\n\n@bob: This should mention review feedback.",
            created_at: workflow.created_at.iso8601,
            state: "succeeded"
          }
        ]
      )
    end

    it "excludes PR comment workflows without comments" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        artifacts: { "pr_comments" => [] }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        artifacts: {}
      )

      expect(payload_for(job)[:feedback_history]).to eq([])
    end

    it "interleaves chat feedback and PR comments chronologically" do
      job = Factories.job_record(repository: repo)
      chat_workflow = Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "succeeded",
        created_at: 2.hours.ago,
        artifacts: { "chat_feedback" => "Chat feedback" }
      )
      pr_workflow = Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "running",
        created_at: 1.hour.ago,
        artifacts: { "pr_comments" => [ { "author" => "reviewer", "body" => "PR feedback" } ] }
      )

      expect(payload_for(job)[:feedback_history]).to eq(
        [
          { kind: "chat_feedback", body: "Chat feedback", created_at: chat_workflow.created_at.iso8601, state: "succeeded" },
          { kind: "pr_comment", body: "@reviewer: PR feedback", created_at: pr_workflow.created_at.iso8601, state: "running" }
        ]
      )
    end

    it "excludes non feedback workflow trigger kinds" do
      job = Factories.job_record(repository: repo)
      %w[initial retry ci_failure].each do |trigger_kind|
        Workflow.create!(
          job: job,
          trigger_kind: trigger_kind,
          state: "succeeded",
          artifacts: {
            "chat_feedback" => "#{trigger_kind} chat feedback",
            "pr_comments" => [ { "author" => "reviewer", "body" => "#{trigger_kind} PR feedback" } ]
          }
        )
      end

      expect(payload_for(job)[:feedback_history]).to eq([])
    end
  end

  describe "#actions_json can_restart" do
    it "is true for an issue job with no active runs" do
      job = Factories.job_record(repository: repo, issue_number: 5)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(true)
    end

    it "is false for a cron job even with no active runs" do
      scheduled_task = ScheduledTask.create!(
        user: user,
        repository: repo,
        name: "Nightly check",
        cron_expression: "0 3 * * *",
        prompt: "Check the repo.",
        kind: "cron",
        pr_pileup_policy: "skip"
      )
      job = Factories.job_record(user: user, repository: repo, kind: "cron", issue_number: nil,
                                 scheduled_task: scheduled_task)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is true for a direct job with no active runs" do
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil,
                                 issue_title: "Fix it")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(true)
    end
  end
end
