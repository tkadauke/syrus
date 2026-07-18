require "rails_helper"

RSpec.describe ChatMemory do
  let(:owner) { Factories.user }
  let(:repo) { Factories.repository(user: owner) }

  def build_memory(**attrs)
    described_class.new({
      user: owner,
      kind: "project_fact",
      scope: "repository",
      scope_id: repo.id,
      content: "The repo uses Rails."
    }.merge(attrs))
  end

  it "accepts valid repository-scoped memories" do
    memory = build_memory
    expect(memory).to be_valid
  end

  it "validates kind and scope enums" do
    memory = build_memory(kind: "habit", scope: "workspace")

    expect(memory).not_to be_valid
    expect(memory.errors[:kind]).to be_present
    expect(memory.errors[:scope]).to be_present
  end

  it "requires repository-scoped memories to have a scope_id" do
    memory = build_memory(scope: "repository", scope_id: nil)

    expect(memory).not_to be_valid
    expect(memory.errors[:scope_id]).to include("must be present for repository scope")
  end

  it "requires global memories to have no scope_id" do
    memory = build_memory(scope: "global", scope_id: repo.id)

    expect(memory).not_to be_valid
    expect(memory.errors[:scope_id]).to include("must be nil for global scope")
  end

  it "limits content length" do
    memory = build_memory(content: "a" * (described_class::CONTENT_MAX_LENGTH + 1))

    expect(memory).not_to be_valid
    expect(memory.errors[:content]).to be_present
  end

  it "only allows published memories for repository scope" do
    memory = build_memory(scope: "global", scope_id: nil, published: true)

    expect(memory).not_to be_valid
    expect(memory.errors[:published]).to include("can only be true for repository scope")
  end

  it "soft deletes memories with the deleting user for audit" do
    memory = build_memory
    memory.save!

    memory.soft_delete_by!(owner)

    expect(memory).to be_deleted
    expect(memory.deleted_by_user).to eq(owner)
  end

  it "soft deletes by a Run actor without setting deleted_by_user" do
    memory = build_memory
    memory.save!
    run = Factories.job.initial_run

    memory.soft_delete_by!(run)

    expect(memory).to be_deleted
    expect(memory.deleted_by_user).to be_nil
  end

  it "requires deleted_at when deleted_by_user is set" do
    memory = build_memory(deleted_by_user: owner)

    expect(memory).not_to be_valid
    expect(memory.errors[:deleted_by_user]).to include("requires deleted_at")
  end

  describe "SCOPE constant" do
    it "includes team and instance in addition to global and repository" do
      expect(described_class::SCOPE).to include("global", "repository", "team", "instance")
    end
  end

  describe "audit events" do
    it "emits a created event on save" do
      memory = build_memory
      expect { memory.save! }.to change(ChatMemoryAuditEvent, :count).by(1)

      event = ChatMemoryAuditEvent.last
      expect(event.event_type).to eq("created")
      expect(event.new_content).to eq(memory.content)
      expect(event.new_kind).to eq(memory.kind)
      expect(event.actor_kind).to eq("system")
    end

    it "emits an updated event when content changes" do
      memory = build_memory
      memory.save!

      expect { memory.update!(content: "New content.") }
        .to change(ChatMemoryAuditEvent, :count).by(1)

      event = ChatMemoryAuditEvent.last
      expect(event.event_type).to eq("updated")
      expect(event.previous_content).to eq("The repo uses Rails.")
      expect(event.new_content).to eq("New content.")
    end

    it "emits an updated event when kind changes" do
      memory = build_memory
      memory.save!

      expect { memory.update!(kind: "feedback") }
        .to change(ChatMemoryAuditEvent, :count).by(1)

      event = ChatMemoryAuditEvent.last
      expect(event.event_type).to eq("updated")
      expect(event.previous_kind).to eq("project_fact")
      expect(event.new_kind).to eq("feedback")
    end

    it "does not emit an updated event for non-audited field changes" do
      memory = build_memory
      memory.save!

      expect { memory.update!(published: true) }
        .not_to change(ChatMemoryAuditEvent, :count)
    end

    it "emits a deleted event via soft_delete_by! with user actor" do
      memory = build_memory
      memory.save!
      initial_count = ChatMemoryAuditEvent.count

      memory.soft_delete_by!(owner)

      new_events = ChatMemoryAuditEvent.where("id > ?", ChatMemoryAuditEvent.order(:id).offset(initial_count - 1).pick(:id) || 0)
      delete_event = ChatMemoryAuditEvent.order(:id).last
      expect(delete_event.event_type).to eq("deleted")
      expect(delete_event.actor_kind).to eq("user")
      expect(delete_event.actor_user).to eq(owner)
      expect(delete_event.previous_content).to eq(memory.content)
    end

    it "emits a deleted event via soft_delete_by! with run actor" do
      memory = build_memory
      memory.save!
      run = Factories.job.initial_run

      memory.soft_delete_by!(run)

      delete_event = ChatMemoryAuditEvent.order(:id).last
      expect(delete_event.event_type).to eq("deleted")
      expect(delete_event.actor_kind).to eq("agent")
      expect(delete_event.actor_run).to eq(run)
      expect(delete_event.actor_user).to be_nil
    end

    it "does not emit an updated event when only deleted_at changes" do
      memory = build_memory
      memory.save!
      initial_count = ChatMemoryAuditEvent.count

      memory.soft_delete_by!(owner)

      # Only the created event + deleted event, no spurious updated event
      events_after = ChatMemoryAuditEvent.where(chat_memory: memory).order(:id)
      expect(events_after.map(&:event_type)).to eq(%w[ created deleted ])
    end
  end

  describe ".visible_to" do
    let(:other_user) { Factories.user }
    let(:other_repo) { Factories.repository(user: owner) }

    it "returns own global, own repo, and published repo memories from other users" do
      own_global = described_class.create!(
        user: owner,
        kind: "user_pref",
        scope: "global",
        content: "Use concise responses."
      )
      own_repo = described_class.create!(
        user: owner,
        kind: "project_fact",
        scope: "repository",
        scope_id: repo.id,
        content: "This repo uses Rails."
      )
      published_other = described_class.create!(
        user: other_user,
        kind: "reference",
        scope: "repository",
        scope_id: repo.id,
        content: "Shared runbook.",
        published: true
      )
      unpublished_other = described_class.create!(
        user: other_user,
        kind: "decision",
        scope: "repository",
        scope_id: repo.id,
        content: "Private draft."
      )
      other_repo_memory = described_class.create!(
        user: owner,
        kind: "feedback",
        scope: "repository",
        scope_id: other_repo.id,
        content: "Different repo."
      )
      deleted_memory = described_class.create!(
        user: owner,
        kind: "feedback",
        scope: "repository",
        scope_id: repo.id,
        content: "Deleted memory."
      )
      deleted_memory.soft_delete_by!(owner)

      visible = described_class.visible_to(owner, repo)

      expect(visible).to include(own_global, own_repo, published_other)
      expect(visible).not_to include(unpublished_other, other_repo_memory, deleted_memory)
    end

    it "accepts multiple repository ids" do
      another_repo = Factories.repository(user: owner)
      own_global = described_class.create!(
        user: owner,
        kind: "user_pref",
        scope: "global",
        content: "Use concise responses."
      )
      own_first_repo = described_class.create!(
        user: owner,
        kind: "project_fact",
        scope: "repository",
        scope_id: repo.id,
        content: "First repo."
      )
      own_second_repo = described_class.create!(
        user: owner,
        kind: "project_fact",
        scope: "repository",
        scope_id: another_repo.id,
        content: "Second repo."
      )

      visible = described_class.visible_to(owner, [ repo.id, another_repo.id ])

      expect(visible).to include(own_global, own_first_repo, own_second_repo)
    end

    it "returns own global memories without repository ids" do
      own_global = described_class.create!(
        user: owner,
        kind: "user_pref",
        scope: "global",
        content: "Use concise responses."
      )
      own_repo = described_class.create!(
        user: owner,
        kind: "project_fact",
        scope: "repository",
        scope_id: repo.id,
        content: "This repo uses Rails."
      )

      visible = described_class.visible_to(owner, [])

      expect(visible).to include(own_global)
      expect(visible).not_to include(own_repo)
    end
  end
end
