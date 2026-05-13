require "rails_helper"

RSpec.describe AgentProviders::SessionStore do
  let(:user) { Factories.user(codex_api_key: "sk-test") }
  let(:job) { Factories.job(user: user) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial") }

  describe "#capture!" do
    it "stores a provider-tagged transcript and logs the capture" do
      messages = []
      capture = AgentProviders::Base::SessionCapture.new(
        provider: "codex",
        session_id: "codex-thread",
        transcript_jsonl: "{\"type\":\"session_meta\"}\n",
        missing_message: nil
      )

      described_class.new(run: run, log: ->(message) { messages << message }).capture!(capture)

      session = run.reload.claude_session
      expect(session.provider).to eq("codex")
      expect(session.session_id).to eq("codex-thread")
      expect(session.transcript_jsonl).to include("session_meta")
      expect(messages.join("\n")).to include("captured codex codex-thread")
    end

    it "logs missing transcript captures without creating a session row" do
      messages = []
      capture = AgentProviders::Base::SessionCapture.new(
        provider: "claude",
        session_id: "S-missing",
        transcript_jsonl: nil,
        missing_message: "no JSONL"
      )

      expect {
        described_class.new(run: run, log: ->(message) { messages << message }).capture!(capture)
      }.not_to change(ClaudeSession, :count)

      expect(messages).to include("no JSONL")
      expect(messages.join("\n")).to include("no transcript captured for claude session S-missing")
    end
  end

  describe ".transcript_for" do
    it "returns the latest transcript for the provider, session, and job" do
      older_run = Run.create!(job: job, step: step, trigger_kind: "initial")
      newer_run = Run.create!(job: job, step: step, trigger_kind: "initial")
      other_job = Factories.job(user: user, repository: job.repository, issue_number: 43)

      ClaudeSession.create!(resumable: older_run, provider: "codex",
                            session_id: "thread", transcript_jsonl: "older\n",
                            created_at: 2.minutes.ago)
      ClaudeSession.create!(resumable: newer_run, provider: "codex",
                            session_id: "thread", transcript_jsonl: "newer\n",
                            created_at: 1.minute.ago)
      ClaudeSession.create!(resumable: other_job.initial_run, provider: "codex",
                            session_id: "thread", transcript_jsonl: "other\n")

      expect(described_class.transcript_for(provider: "codex", session_id: "thread", job: job))
        .to eq("newer\n")
    end
  end
end
