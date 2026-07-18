class ChatMemory < ApplicationRecord
  KIND = %w[ user_pref project_fact feedback reference decision ].freeze
  SCOPE = %w[ global repository team instance ].freeze
  TOOL_SCOPES = %w[ global repository ].freeze
  SOURCE_TYPES = %w[ chat job workflow run manual insight admin ].freeze
  AUTHORS = %w[ user system agent ].freeze
  VISIBILITIES = %w[ private repository team instance ].freeze
  CONTENT_MAX_LENGTH = 2000

  belongs_to :user
  belongs_to :deleted_by_user, class_name: "User", optional: true
  belongs_to :repository, optional: true, foreign_key: :scope_id

  enum :kind, KIND.index_with(&:itself), validate: true
  enum :scope, SCOPE.index_with(&:itself), validate: true

  validates :content, presence: true, length: { maximum: CONTENT_MAX_LENGTH }
  validate :scope_id_matches_scope
  validate :published_only_for_repository_scope
  validate :deleted_by_requires_deleted_at

  after_create :emit_created_audit_event
  after_update :emit_updated_audit_event

  scope :active, -> { where(deleted_at: nil) }
  scope :global_scope, -> { where(scope: "global", scope_id: nil) }
  scope :repository_scope, ->(repo_or_id) { where(scope: "repository", scope_id: repository_id_for(repo_or_id)) }
  scope :published, -> { where(published: true) }
  scope :for_user, ->(user) { where(user: user) }
  scope :visible_to, ->(user, repositories) {
    user_id = user.respond_to?(:id) ? user.id : user
    repository_ids = Array(repositories).map { |repository| repository_id_for(repository) }.compact
    own_global = active.where(user_id: user_id, scope: "global", scope_id: nil)

    if repository_ids.empty?
      own_global
    else
      own_repository = active.where(user_id: user_id, scope: "repository", scope_id: repository_ids)
      shared_repository = active.where.not(user_id: user_id)
                                .where(scope: "repository", scope_id: repository_ids, published: true)

      own_global.or(own_repository).or(shared_repository)
    end
  }

  def self.repository_id_for(repo_or_id)
    repo_or_id.respond_to?(:id) ? repo_or_id.id : repo_or_id
  end

  def soft_delete_by!(actor)
    update!(deleted_at: Time.current, deleted_by_user: actor.is_a?(User) ? actor : nil)
    emit_deleted_audit_event(actor)
  end

  def deleted?
    deleted_at.present?
  end

  private

  def emit_created_audit_event
    ChatMemoryAuditEvent.record!(
      chat_memory: self,
      event_type: "created",
      actor: nil,
      new_content: content,
      new_kind: kind,
      new_confidence: confidence
    )
  end

  def emit_updated_audit_event
    return unless saved_change_to_content? || saved_change_to_kind? || saved_change_to_confidence?
    return if saved_change_to_deleted_at?

    ChatMemoryAuditEvent.record!(
      chat_memory: self,
      event_type: "updated",
      actor: nil,
      previous_content: content_before_last_save,
      new_content: content,
      previous_kind: kind_before_last_save,
      new_kind: kind,
      previous_confidence: confidence_before_last_save,
      new_confidence: confidence
    )
  end

  def emit_deleted_audit_event(actor)
    ChatMemoryAuditEvent.record!(
      chat_memory: self,
      event_type: "deleted",
      actor: actor,
      previous_content: content,
      previous_kind: kind,
      previous_confidence: confidence
    )
  end

  def scope_id_matches_scope
    if repository? && scope_id.blank?
      errors.add(:scope_id, "must be present for repository scope")
    elsif global? && scope_id.present?
      errors.add(:scope_id, "must be nil for global scope")
    end
  end

  def published_only_for_repository_scope
    errors.add(:published, "can only be true for repository scope") if published? && !repository?
  end

  def deleted_by_requires_deleted_at
    errors.add(:deleted_by_user, "requires deleted_at") if deleted_by_user_id.present? && deleted_at.blank?
  end
end
