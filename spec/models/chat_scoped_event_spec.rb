require "rails_helper"

RSpec.describe ChatScopedEvent do
  describe ".record!" do
    it "returns the existing event for the same chat and dedupe key" do
      chat = ChatSession.create!(user: Factories.user)
      existing = described_class.create!(
        chat_session: chat,
        source_kind: "pr_merged",
        payload: { "title" => "done" },
        dedupe_key: "job-1"
      )

      event = described_class.record!(
        chat_session: chat,
        source_kind: "pr_merged",
        payload: { "title" => "duplicate" },
        dedupe_key: "job-1"
      )

      expect(event).to eq(existing)
      expect(described_class.where(chat_session: chat, dedupe_key: "job-1").count).to eq(1)
    end

    it "returns the row that won a concurrent insert race" do
      chat = ChatSession.create!(user: Factories.user)
      inserted = described_class.create!(
        chat_session: chat,
        source_kind: "pr_merged",
        payload: { "title" => "winner" },
        dedupe_key: "job-1"
      )

      allow(described_class).to receive(:find_by).and_call_original
      allow(described_class).to receive(:find_by)
        .with(chat_session: chat, dedupe_key: "job-1")
        .and_return(nil, inserted)
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

      event = described_class.record!(
        chat_session: chat,
        source_kind: "pr_merged",
        payload: { "title" => "duplicate" },
        dedupe_key: "job-1"
      )

      expect(event).to eq(inserted)
    end

    it "retries once when a duplicate insert is not yet visible" do
      chat = ChatSession.create!(user: Factories.user)

      allow(described_class).to receive(:find_by).and_call_original
      allow(described_class).to receive(:find_by)
        .with(chat_session: chat, dedupe_key: "job-1")
        .and_return(nil, nil, nil)
      attempts = 0
      allow(described_class).to receive(:create!) do |attributes|
        attempts += 1
        raise ActiveRecord::RecordNotUnique if attempts == 1

        described_class.new(attributes)
      end

      event = described_class.record!(
        chat_session: chat,
        source_kind: "pr_merged",
        payload: { "title" => "duplicate" },
        dedupe_key: "job-1"
      )

      expect(event).to be_a(described_class)
      expect(attempts).to eq(2)
    end
  end
end
