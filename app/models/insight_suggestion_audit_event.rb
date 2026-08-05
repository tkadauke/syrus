class InsightSuggestionAuditEvent < ApplicationRecord
  EVENT_TYPES = %w[ updated ].freeze
  ACTOR_KINDS = %w[ user agent system ].freeze

  belongs_to :insight_suggestion
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :actor_run, class_name: "Run", optional: true

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }
  validates :actor_kind, presence: true, inclusion: { in: ACTOR_KINDS }
  validates :reason, presence: true

  before_update { raise ActiveRecord::ReadOnlyRecord, "InsightSuggestionAuditEvent is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "InsightSuggestionAuditEvent is append-only" unless destroyed_by_association }

  def self.record!(insight_suggestion:, event_type:, actor:, previous_values:, new_values:, reason:)
    actor_kind, actor_user, actor_run = resolve_actor(actor)

    create!(
      insight_suggestion: insight_suggestion,
      event_type: event_type,
      actor_kind: actor_kind,
      actor_user: actor_user,
      actor_run: actor_run,
      previous_values: previous_values,
      new_values: new_values,
      reason: reason,
      created_at: Time.current
    )
  end

  def self.resolve_actor(actor)
    case actor
    when User
      [ "user", actor, nil ]
    when Run
      [ "agent", nil, actor ]
    else
      [ "system", nil, nil ]
    end
  end
  private_class_method :resolve_actor
end
