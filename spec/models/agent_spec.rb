require "rails_helper"

RSpec.describe Agent do
  let(:run) { Factories.job.initial_run }
  let(:chat_user) { Factories.user }
  let(:chat_repository) { Factories.repository(user: chat_user) }
  let(:chat_session) { ChatSession.create!(user: chat_user, repository: chat_repository) }

  describe ".find_or_create_for!" do
    it "creates the first Agent for a resumable" do
      agent = described_class.find_or_create_for!(run)

      expect(agent).to be_persisted
      expect(agent.resumable).to eq(run)
    end

    it "returns the existing Agent when the unique index loses a creation race" do
      existing = nil
      first_call_entered = Queue.new
      release_first_call = Queue.new
      first_call_created = Queue.new
      second_call_entered = Queue.new
      original_create = described_class.method(:create!)
      create_calls = Queue.new

      allow(described_class).to receive(:create!) do |attributes|
        create_calls << true

        if create_calls.size == 1
          first_call_entered << true
          release_first_call.pop
          existing = original_create.call(attributes)
          first_call_created << true
          existing
        else
          second_call_entered << true
          first_call_created.pop
          raise ActiveRecord::RecordNotUnique.new("index_agents_on_resumable")
        end
      end

      first = Thread.new { described_class.find_or_create_for!(run) }
      first_call_entered.pop
      second = Thread.new { described_class.find_or_create_for!(run) }
      second_call_entered.pop
      release_first_call << true

      results = [ first, second ].map(&:value)

      expect(results).to all(eq(existing))
      expect(described_class.where(resumable: run).count).to eq(1)
    end

    it "returns the existing Agent when the uniqueness validation loses a creation race" do
      existing = described_class.create!(resumable: run)
      duplicate = described_class.new(resumable: run)
      duplicate.valid?
      error = ActiveRecord::RecordInvalid.new(duplicate)

      allow(described_class).to receive(:create!).and_raise(error)

      expect(described_class.find_or_create_for!(run)).to eq(existing)
    end

    it "reraises unrelated validation failures" do
      invalid = described_class.new
      invalid.valid?

      allow(described_class).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid))

      expect { described_class.find_or_create_for!(run) }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "resumable polymorphism" do
    it "resolves a real Run resumable" do
      agent = described_class.create!(resumable: run)

      expect(agent.reload.resumable).to eq(run)
      expect(run.reload.agent).to eq(agent)
    end

    it "resolves a real ChatSession resumable" do
      agent = described_class.create!(resumable: chat_session)

      expect(agent.reload.resumable).to eq(chat_session)
      expect(chat_session.reload.agent).to eq(agent)
    end
  end

  describe "#provider_session" do
    it "delegates to the resumable provider_session" do
      provider_session = run.create_provider_session!(session_id: "uuid", transcript_jsonl: "captured")
      agent = described_class.create!(resumable: run)

      expect(agent.provider_session).to eq(provider_session)
    end
  end
end
