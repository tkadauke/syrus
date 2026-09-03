module AgentMemory
  # Append-only history of every write to an Entry.
  class AuditEvent < ApplicationRecord
    self.table_name = "agent_memory_audit_events"

    EVENT_TYPES = %w[ created updated deleted ].freeze
    ACTOR_KINDS = %w[ user agent system ].freeze

    belongs_to :entry, class_name: "AgentMemory::Entry", inverse_of: :audit_events
    belongs_to :actor_user, class_name: "::User", optional: true
    belongs_to :actor_run, class_name: "::Run", optional: true

    validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
    validates :actor_kind, presence: true, inclusion: { in: ACTOR_KINDS }

    before_update { raise ActiveRecord::ReadOnlyRecord, "AgentMemory::AuditEvent is append-only" }
    before_destroy { raise ActiveRecord::ReadOnlyRecord, "AgentMemory::AuditEvent is append-only" unless destroyed_by_association }

    # Append an audit event for an Entry write.
    # actor: nil (system), a User, or a Run.
    def self.record!(entry:, event_type:, actor:, **content_changes)
      actor_kind, actor_user, actor_run = resolve_actor(actor)

      create!(
        entry: entry,
        event_type: event_type,
        actor_kind: actor_kind,
        actor_user: actor_user,
        actor_run: actor_run,
        **content_changes
      )
    end

    def self.resolve_actor(actor)
      case actor
      when ::User
        [ "user", actor, nil ]
      when ::Run
        [ "agent", nil, actor ]
      else
        [ "system", nil, nil ]
      end
    end
    private_class_method :resolve_actor
  end
end
