require "rails_helper"
require "tmpdir"

RSpec.describe ChatCodingRelayRefreshJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before do
    @data_root = Dir.mktmpdir("syrus-relay-refresh-data")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(@data_root) if @data_root
  end

  it "runs on the chat queue" do
    expect(described_class.new.queue_name).to eq("chat")
  end

  it "no-ops when the chat has no repository" do
    chat_session = ChatSession.create!(user: user)

    expect(ChatWorkspace).not_to receive(:refresh_relay_credentials!)

    described_class.perform_now(chat_session.id)
  end

  context "when the checkout exists on this worker's disk" do
    it "refreshes relay credentials for the attached repository" do
      chat_session = ChatSession.create!(user: user, repository: repository)
      path = ChatWorkspace.repo_path_for(chat_session, repository)
      FileUtils.mkdir_p(path.join(".git"))

      expect(ChatWorkspace).to receive(:refresh_relay_credentials!).with(chat_session, repository)

      described_class.perform_now(chat_session.id)
    end
  end

  context "when the checkout is missing on this worker's disk" do
    it "does not clone, and quietly no-ops when workspace_storage_key was never recorded" do
      chat_session = ChatSession.create!(user: user, repository: repository)

      expect(ChatWorkspace).not_to receive(:refresh_relay_credentials!)
      expect(ChatWorkspace).not_to receive(:ensure_coding_checkout!)
      expect(Rails.logger).not_to receive(:error)

      described_class.perform_now(chat_session.id)

      chat_session.reload
      expect(chat_session.coding_checkout_prepare_status).to be_nil
    end

    it "does not clone, and quietly no-ops when routed to a different worker than the one that recorded the checkout" do
      chat_session = ChatSession.create!(
        user: user, repository: repository, workspace_storage_key: "some-other-worker-key"
      )

      expect(ChatWorkspace).not_to receive(:refresh_relay_credentials!)
      expect(ChatWorkspace).not_to receive(:ensure_coding_checkout!)

      described_class.perform_now(chat_session.id)

      chat_session.reload
      expect(chat_session.coding_checkout_prepare_status).to be_nil
    end

    it "fails loudly instead of silently no-opping when correctly routed but the checkout is genuinely gone" do
      chat_session = ChatSession.create!(
        user: user, repository: repository, workspace_storage_key: WorkerStorageIdentity.key,
        coding_relay_address: "127.0.0.1:9283", coding_relay_token: "stale-token"
      )

      expect(ChatWorkspace).not_to receive(:refresh_relay_credentials!)
      expect(ChatWorkspace).not_to receive(:ensure_coding_checkout!)
      expect(Rails.logger).to receive(:error).with(a_string_matching(/chat #{chat_session.id}.*missing.*worker/i))

      described_class.perform_now(chat_session.id)

      chat_session.reload
      expect(chat_session.coding_checkout_prepare_status).to eq("workspace_lost")
      expect(chat_session.coding_checkout_prepare_failure).to be_present
      expect(chat_session.coding_checkout_prepare_finished_at).to be_present
      expect(chat_session.coding_relay_address).to be_nil
      expect(chat_session.coding_relay_token).to be_nil
      expect(ChatWorkspace.repo_path_for(chat_session, repository)).not_to exist
    end
  end
end
