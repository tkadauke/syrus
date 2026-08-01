require "rails_helper"

RSpec.describe McpToolContext do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe ".from_run" do
    let(:run) { Factories.job.initial_run }

    it "sets surface to :run" do
      context = described_class.from_run(run)
      expect(context.surface).to eq(:run)
    end

    it "exposes the job's user and repository" do
      context = described_class.from_run(run)
      expect(context.user).to eq(run.job.user)
      expect(context.repository).to eq(run.job.repository)
    end

    it "exposes the job, workflow, and run" do
      context = described_class.from_run(run)
      expect(context.job).to eq(run.job)
      expect(context.workflow).to eq(run.workflow)
      expect(context.run).to eq(run)
    end

    it "restricts allowed_memory_scopes to repository only" do
      context = described_class.from_run(run)
      expect(context.allowed_memory_scopes).to eq([ "repository" ])
    end

    it "sets allowed_repository_ids to the job's repository" do
      context = described_class.from_run(run)
      expect(context.allowed_repository_ids).to eq([ run.job.repository_id ])
    end

    it "returns true for run?" do
      expect(described_class.from_run(run).run?).to be true
    end

    it "returns false for chat?" do
      expect(described_class.from_run(run).chat?).to be false
    end

    it "assigns a WORKFLOW_* role" do
      context = described_class.from_run(run)
      expect(AgentRole::WORKFLOW_ROLES).to include(context.role)
    end

    it "assigns WORKFLOW_REBASE_CONFLICT for agent_rebase step kind" do
      run.step.update_columns(kind: "agent_rebase")
      context = described_class.from_run(run.reload)
      expect(context.role).to eq(AgentRole::WORKFLOW_REBASE_CONFLICT)
    end

    it "assigns WORKFLOW_IMPLEMENT for merge_train_reconcile step kind" do
      run.step.update_columns(kind: "merge_train_reconcile")
      context = described_class.from_run(run.reload)
      expect(context.role).to eq(AgentRole::WORKFLOW_IMPLEMENT)
    end

    it "assigns WORKFLOW_SUMMARY_TEST_PLAN for summarize step kind" do
      run.step.update_columns(kind: "summarize")
      context = described_class.from_run(run.reload)
      expect(context.role).to eq(AgentRole::WORKFLOW_SUMMARY_TEST_PLAN)
    end

    it "assigns WORKFLOW_IMPLEMENT for grader step kind" do
      run.step.update_columns(kind: "grader")
      context = described_class.from_run(run.reload)
      expect(context.role).to eq(AgentRole::WORKFLOW_IMPLEMENT)
    end

    it "assigns WORKFLOW_ADVERSARIAL_REVIEWER for adversarial_review step kind" do
      run.step.update_columns(kind: "adversarial_review")
      context = described_class.from_run(run.reload)
      expect(context.role).to eq(AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER)
    end

    it "assigns WORKFLOW_RECONCILIATION_FEEDBACK for the reconciliation Job of a feedback-mode Epic" do
      epic = Factories.epic(user: user, repository: repository, reconciliation_mode: "feedback")
      # Create job without epic so it gets an initial run, then associate it
      recon_job = Factories.job(user: user, repository: repository)
      recon_job.update!(epic: epic)
      epic.update!(reconciliation_job_id: recon_job.id)

      context = described_class.from_run(recon_job.initial_run)
      expect(context.role).to eq(AgentRole::WORKFLOW_RECONCILIATION_FEEDBACK)
    end

    it "assigns WORKFLOW_IMPLEMENT (not WORKFLOW_RECONCILIATION_FEEDBACK) for a non-reconciliation Job in a feedback-mode Epic" do
      epic = Factories.epic(user: user, repository: repository, reconciliation_mode: "feedback")
      sibling_job = Factories.job(user: user, repository: repository)
      other_job   = Factories.job(user: user, repository: repository)
      sibling_job.update!(epic: epic)
      other_job.update!(epic: epic)
      # reconciliation_job_id points to other_job, so sibling_job is not the recon job
      epic.update!(reconciliation_job_id: other_job.id)

      context = described_class.from_run(sibling_job.initial_run)
      expect(context.role).to eq(AgentRole::WORKFLOW_IMPLEMENT)
    end

    it "assigns WORKFLOW_IMPLEMENT for the reconciliation Job of a pr-mode Epic" do
      epic = Factories.epic(user: user, repository: repository, reconciliation_mode: "pr")
      recon_job = Factories.job(user: user, repository: repository)
      recon_job.update!(epic: epic)
      epic.update!(reconciliation_job_id: recon_job.id)

      context = described_class.from_run(recon_job.initial_run)
      expect(context.role).to eq(AgentRole::WORKFLOW_IMPLEMENT)
    end

    it "exposes submit_adversarial_review to an adversarial_review step" do
      run.step.update_columns(kind: "adversarial_review")
      context = described_class.from_run(run.reload)

      tools = McpToolPolicy.for(context)
      expect(tools).to include(SyrusMcp::SubmitAdversarialReviewTool)
      expect(tools).not_to include(SyrusMcp::SubmitSummaryTool)
    end

    it "does not expose submit_adversarial_review to a grader step" do
      run.step.update_columns(kind: "grader")
      context = described_class.from_run(run.reload)

      tools = McpToolPolicy.for(context)
      expect(tools).not_to include(SyrusMcp::SubmitAdversarialReviewTool)
      expect(tools).to include(SyrusMcp::SubmitSummaryTool)
    end
  end

  describe ".from_chat_session" do
    let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

    it "sets surface to :chat" do
      context = described_class.from_chat_session(chat_session)
      expect(context.surface).to eq(:chat)
    end

    it "exposes the session's user and repository" do
      context = described_class.from_chat_session(chat_session)
      expect(context.user).to eq(user)
      expect(context.repository).to eq(repository)
    end

    it "exposes the chat_session" do
      context = described_class.from_chat_session(chat_session)
      expect(context.chat_session).to eq(chat_session)
    end

    it "allows both global and repository memory scopes" do
      context = described_class.from_chat_session(chat_session)
      expect(context.allowed_memory_scopes).to contain_exactly("global", "repository")
    end

    it "populates allowed_repository_ids from attached repositories" do
      second_repo = Factories.repository(user: user)
      chat_session.chat_attachments.create!(attachable: second_repo)

      context = described_class.from_chat_session(chat_session)
      expect(context.allowed_repository_ids).to contain_exactly(repository.id, second_repo.id)
    end

    it "returns false for run?" do
      expect(described_class.from_chat_session(chat_session).run?).to be false
    end

    it "returns true for chat?" do
      expect(described_class.from_chat_session(chat_session).chat?).to be true
    end

    it "assigns CHAT_PLANNER role for a planning session" do
      context = described_class.from_chat_session(chat_session)
      expect(context.role).to eq(AgentRole::CHAT_PLANNER)
    end

    it "assigns CHAT_ADMIN role for a supervisor session" do
      supervisor_session = ChatSession.create!(user: user, repository: repository, system_kind: "supervisor")
      context = described_class.from_chat_session(supervisor_session)
      expect(context.role).to eq(AgentRole::CHAT_ADMIN)
    end

    it "assigns CHAT_CODING role for a coding session" do
      coding_session = ChatSession.create!(user: user, repository: repository, mode: "coding")
      context = described_class.from_chat_session(coding_session)
      expect(context.role).to eq(AgentRole::CHAT_CODING)
    end

    it "assigns CHAT_LOCAL role for a local mode session" do
      local_session = ChatSession.create!(user: user, repository: repository, mode: "local")
      context = described_class.from_chat_session(local_session)
      expect(context.role).to eq(AgentRole::CHAT_LOCAL)
    end
  end

  describe ".from_server_context" do
    it "builds from a run-sidecar server_context hash" do
      run = Factories.job.initial_run
      context = described_class.from_server_context({ run_id: run.id })

      expect(context.surface).to eq(:run)
      expect(context.user).to eq(run.job.user)
    end

    it "builds from a chat-sidecar server_context hash" do
      chat_session = ChatSession.create!(user: user, repository: repository)
      context = described_class.from_server_context({ chat_session: chat_session })

      expect(context.surface).to eq(:chat)
      expect(context.user).to eq(user)
    end
  end
end
