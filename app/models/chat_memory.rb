class ChatMemory < ApplicationRecord
  KIND = %w[ user_pref project_fact feedback reference decision ].freeze
  SCOPE = %w[ global repository ].freeze
  CONTENT_MAX_LENGTH = 2000

  belongs_to :user
  belongs_to :repository, optional: true, foreign_key: :scope_id

  enum :kind, KIND.index_with(&:itself), validate: true
  enum :scope, SCOPE.index_with(&:itself), validate: true

  validates :content, presence: true, length: { maximum: CONTENT_MAX_LENGTH }
  validate :scope_id_matches_scope
  validate :published_only_for_repository_scope

  scope :global_scope, -> { where(scope: "global", scope_id: nil) }
  scope :repository_scope, ->(repo_or_id) { where(scope: "repository", scope_id: repository_id_for(repo_or_id)) }
  scope :published, -> { where(published: true) }
  scope :for_user, ->(user) { where(user: user) }
  scope :visible_to, ->(user, repositories) {
    user_id = user.respond_to?(:id) ? user.id : user
    repository_ids = Array(repositories).map { |repository| repository_id_for(repository) }.compact
    own_global = where(user_id: user_id, scope: "global", scope_id: nil)

    if repository_ids.empty?
      own_global
    else
      own_repository = where(user_id: user_id, scope: "repository", scope_id: repository_ids)
      shared_repository = where.not(user_id: user_id)
                               .where(scope: "repository", scope_id: repository_ids, published: true)

      own_global.or(own_repository).or(shared_repository)
    end
  }

  def self.repository_id_for(repo_or_id)
    repo_or_id.respond_to?(:id) ? repo_or_id.id : repo_or_id
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
end
