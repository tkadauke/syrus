module DesignDocs
  class DesignDoc < ApplicationRecord
    self.table_name = "design_docs"

    VISIBILITIES = %w[private public].freeze
    STATES = %w[draft accepted archived].freeze

    belongs_to :owner_user, class_name: "User"
    belongs_to :origin_chat_session, class_name: "ChatSession", optional: true
    belongs_to :current_version, class_name: "DesignDocs::DesignDocVersion", optional: true

    has_many :design_doc_repositories, class_name: "DesignDocs::DesignDocRepository", dependent: :destroy
    has_many :repositories, through: :design_doc_repositories
    has_many :collaborators, class_name: "DesignDocs::DesignDocCollaborator", dependent: :destroy
    has_many :collaborator_users, through: :collaborators, source: :user
    has_many :versions, class_name: "DesignDocs::DesignDocVersion", dependent: :destroy
    has_many :anchors, class_name: "DesignDocs::DesignDocAnchor", dependent: :destroy
    has_many :threads, class_name: "DesignDocs::DesignDocThread", dependent: :destroy
    has_many :suggestions, class_name: "DesignDocs::DesignDocSuggestion", dependent: :destroy

    before_validation :normalize_title
    before_validation :normalize_markdown
    before_destroy :clear_current_version_reference, prepend: true

    validates :title, presence: true
    validates :markdown, presence: true
    validates :visibility, presence: true, inclusion: { in: VISIBILITIES }
    validates :state, presence: true, inclusion: { in: STATES }
    validate :current_version_belongs_to_doc

    scope :newest_first, -> { order(updated_at: :desc, id: :desc) }
    scope :publicly_visible, -> { where(visibility: "public") }

    def self.visible_to(user)
      user = User.find(user) unless user.is_a?(User)
      collaborator_doc_ids = DesignDocs::DesignDocCollaborator.where(user: user).select(:design_doc_id)
      public_doc_ids = DesignDocs::DesignDocRepository
        .where(repository_id: Repository.accessible_to(user).select(:id))
        .select(:design_doc_id)

      where(owner_user: user)
        .or(where(id: collaborator_doc_ids))
        .or(publicly_visible.where(id: public_doc_ids))
    end

    def display_id
      "DOC-#{id}"
    end

    def display_name
      "#{display_id} #{title}"
    end

    def private?
      visibility == "private"
    end

    def public?
      visibility == "public"
    end

    private

    def normalize_title
      self.title = title.to_s.strip
    end

    def normalize_markdown
      self.markdown = markdown.to_s
    end

    def current_version_belongs_to_doc
      return if current_version.nil?
      return if current_version.design_doc_id.nil? || current_version.design_doc_id == id

      errors.add(:current_version, "must belong to this design doc")
    end

    def clear_current_version_reference
      update_column(:current_version_id, nil) if current_version_id.present?
    end
  end
end
