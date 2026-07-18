require "rails_helper"

RSpec.describe ChatMemoryAuditEvent do
  let(:owner) { Factories.user }
  let(:repo) { Factories.repository(user: owner) }

  def create_memory(**attrs)
    ChatMemory.create!({
      user: owner,
      kind: "project_fact",
      scope: "repository",
      scope_id: repo.id,
      content: "The repo uses Rails."
    }.merge(attrs))
  end

  describe ".record!" do
    it "creates an audit event with system actor when actor is nil" do
      memory = create_memory
      event = described_class.record!(
        chat_memory: memory,
        event_type: "created",
        actor: nil,
        new_content: memory.content,
        new_kind: memory.kind
      )

      expect(event.actor_kind).to eq("system")
      expect(event.actor_user).to be_nil
      expect(event.actor_run).to be_nil
    end

    it "creates an audit event with user actor kind" do
      memory = create_memory
      event = described_class.record!(
        chat_memory: memory,
        event_type: "updated",
        actor: owner,
        new_content: "Updated content"
      )

      expect(event.actor_kind).to eq("user")
      expect(event.actor_user).to eq(owner)
      expect(event.actor_run).to be_nil
    end

    it "creates an audit event with agent actor kind from a Run" do
      run = Factories.job.initial_run
      memory = create_memory
      event = described_class.record!(
        chat_memory: memory,
        event_type: "deleted",
        actor: run,
        previous_content: memory.content
      )

      expect(event.actor_kind).to eq("agent")
      expect(event.actor_user).to be_nil
      expect(event.actor_run).to eq(run)
    end

    it "stores content snapshots" do
      memory = create_memory(content: "Before")
      event = described_class.record!(
        chat_memory: memory,
        event_type: "updated",
        actor: owner,
        previous_content: "Before",
        new_content: "After",
        previous_kind: "user_pref",
        new_kind: "project_fact",
        previous_confidence: 0.5,
        new_confidence: 0.9
      )

      expect(event.previous_content).to eq("Before")
      expect(event.new_content).to eq("After")
      expect(event.previous_kind).to eq("user_pref")
      expect(event.new_kind).to eq("project_fact")
      expect(event.previous_confidence).to be_within(0.01).of(0.5)
      expect(event.new_confidence).to be_within(0.01).of(0.9)
    end
  end

  describe "immutability" do
    it "raises on update" do
      memory = create_memory
      event = described_class.record!(
        chat_memory: memory,
        event_type: "created",
        actor: nil,
        new_content: memory.content
      )

      expect { event.update!(event_type: "updated") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "raises on destroy" do
      memory = create_memory
      event = described_class.record!(
        chat_memory: memory,
        event_type: "created",
        actor: nil,
        new_content: memory.content
      )

      expect { event.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end
end
