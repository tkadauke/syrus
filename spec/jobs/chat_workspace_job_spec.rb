require "rails_helper"

RSpec.describe ChatWorkspaceJob, type: :job do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let!(:chat_session) { ChatSession.create!(repository: repository, user: user, last_message_at: 1.hour.ago) }

  describe "#perform" do
    it "refreshes the workspace and records the fetched default-branch head" do
      path = Rails.root
      git = instance_double(GitRunner)
      allow(ChatWorkspace).to receive(:refresh!).with(repository).and_return(path)
      allow(GitRunner).to receive(:new).and_return(git)
      allow(git).to receive(:run)
        .with("rev-parse", "origin/main", chdir: path.to_s)
        .and_return("abc123\n")

      expect {
        described_class.perform_now(repository.id, action: :refresh)
      }.to change { chat_session.messages.where(role: "system").count }.by(1)

      expect(chat_session.messages.last.content).to eq("text" => "Workspace refreshed: abc123.")
      expect(chat_session.reload.last_message_at).to be > 1.minute.ago
    end

    it "resets the workspace and records completion" do
      allow(ChatWorkspace).to receive(:reset!).with(repository)

      expect {
        described_class.perform_now(repository.id, action: "reset")
      }.to change { chat_session.messages.where(role: "system").count }.by(1)

      expect(chat_session.messages.last.content).to eq("text" => "Workspace reset.")
    end

    it "rejects unknown actions" do
      expect {
        described_class.perform_now(repository.id, action: :polish)
      }.to raise_error(ArgumentError, "unknown chat workspace action: polish")
    end
  end
end
