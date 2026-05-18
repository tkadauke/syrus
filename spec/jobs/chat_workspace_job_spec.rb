require "rails_helper"

RSpec.describe ChatWorkspaceJob, type: :job do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let!(:chat_session) { ChatSession.create!(repository: repository, user: user, last_message_at: 1.hour.ago) }

  it "enqueues chat workspace work on the chat queue" do
    expect {
      described_class.perform_later(chat_session.id, action: :refresh)
    }.to have_enqueued_job(described_class).with(chat_session.id, action: :refresh).on_queue("chat")
  end

  it "serializes with chat turns for the same chat session" do
    user_message = chat_session.messages.create!(role: "user", content: { "text" => "Refresh after this" })

    turn_job = ChatTurnJob.new(chat_session.id, user_message.id)
    workspace_job = described_class.new(chat_session.id, action: :refresh)

    expect(workspace_job.concurrency_key).to eq(turn_job.concurrency_key)
    expect(workspace_job.concurrency_key).to eq("repository_chat/chat:#{chat_session.id}")
  end

  describe "#perform" do
    it "refreshes the workspace and records the fetched default-branch head" do
      path = Rails.root
      git = instance_double(GitRunner)
      allow(ChatWorkspace).to receive(:refresh!).with(chat_session, repository).and_return(path)
      allow(GitRunner).to receive(:new).and_return(git)
      allow(git).to receive(:run)
        .with("rev-parse", "origin/main", chdir: path.to_s)
        .and_return("abc123\n")

      expect {
        described_class.perform_now(chat_session.id, action: :refresh)
      }.to change { chat_session.messages.where(role: "system").count }.by(1)

      expect(chat_session.messages.last.content).to eq("text" => "Workspace refreshed: abc123.")
      expect(chat_session.reload.last_message_at).to be > 1.minute.ago
    end

    it "resets the workspace and records completion" do
      allow(ChatWorkspace).to receive(:reset!).with(chat_session)

      expect {
        described_class.perform_now(chat_session.id, action: "reset")
      }.to change { chat_session.messages.where(role: "system").count }.by(1)

      expect(chat_session.messages.last.content).to eq("text" => "Workspace reset.")
    end

    it "rejects unknown actions" do
      expect {
        described_class.perform_now(chat_session.id, action: :polish)
      }.to raise_error(ArgumentError, "unknown chat workspace action: polish")
    end
  end
end
