class ChatMemory < ApplicationRecord
  KIND = %w[ user_pref project_fact feedback reference decision ].freeze
  SCOPE = %w[ global repository ].freeze
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

  scope :active, -> { where(deleted_at: nil) }
  scope :global_scope, -> { where(scope: "global", scope_id: nil) }
  scope :repository_scope, ->(repo_or_id) { where(scope: "repository", scope_id: repository_id_for(repo_or_id)) }
  scope :published, -> { where(published: true) }
  scope :for_user, ->(user) { where(user: user) }
  scope :visible_to, ->(user, repository) {
    user_id = user.respond_to?(:id) ? user.id : user
    repository_id = repository_id_for(repository)

    active.where(
      <<~SQL.squish,
        (
          chat_memories.user_id = :user_id
          AND (
            (chat_memories.scope = :global_scope AND chat_memories.scope_id IS NULL)
            OR (chat_memories.scope = :repository_scope AND chat_memories.scope_id = :repository_id)
          )
        )
        OR (
          chat_memories.user_id != :user_id
          AND chat_memories.scope = :repository_scope
          AND chat_memories.scope_id = :repository_id
          AND chat_memories.published = :published
        )
      SQL
      user_id: user_id,
      repository_id: repository_id,
      global_scope: "global",
      repository_scope: "repository",
      published: true
    )
  }

  def self.repository_id_for(repo_or_id)
    repo_or_id.respond_to?(:id) ? repo_or_id.id : repo_or_id
  end

  def soft_delete_by!(actor)
    update!(deleted_at: Time.current, deleted_by_user: actor)
  end

  def deleted?
    deleted_at.present?
  end

  private

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
