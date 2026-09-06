module DesignDocs
  class DesignDoc < ApplicationRecord
    self.table_name = "design_docs"

    VISIBILITIES = %w[private public].freeze
    STATES = %w[draft accepted archived].freeze
    PREVIEW_WORD_LIMIT = 100

    belongs_to :owner_user, class_name: "User"
    belongs_to :origin_chat_session, class_name: "ChatSession", optional: true
    belongs_to :current_version, class_name: "DesignDocs::DesignDocVersion", optional: true

    has_many :design_doc_repositories, class_name: "DesignDocs::DesignDocRepository", dependent: :destroy
    has_many :repositories, through: :design_doc_repositories
    has_many :collaborators, class_name: "DesignDocs::DesignDocCollaborator", dependent: :destroy
    has_many :collaborator_users, through: :collaborators, source: :user
    has_many :versions, class_name: "DesignDocs::DesignDocVersion", dependent: :destroy
    has_many :agent_runs, class_name: "DesignDocs::DesignDocAgentRun", dependent: :destroy
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

    def comments_count
      threads.joins(:comments).count
    end

    # A short, hover-preview-sized excerpt of the body: hidden Syrus anchor
    # markers stripped, clamped to roughly PREVIEW_WORD_LIMIT words so a
    # popup never has to render (or fetch) the whole document. Paragraph
    # boundaries (blank lines, and the line break after a heading) are kept
    # intact rather than collapsed to spaces -- otherwise a leading "#
    # Heading" has no newline left to end it, and the whole clamped excerpt
    # renders as one giant heading instead of a heading followed by text.
    def preview_text(word_limit: PREVIEW_WORD_LIMIT)
      visible = DesignDocs::AnchorMarkers.strip(markdown).strip
      normalized = visible.gsub(/^(#+\s[^\n]*)\n(?!\n)/, "\\1\n\n")
      paragraphs = normalized.split(/\n{2,}/).map { |block| block.split(/\s+/).reject(&:empty?) }.reject(&:empty?)

      total_words = paragraphs.sum(&:length)
      return visible if total_words <= word_limit

      remaining = word_limit
      clamped = []
      paragraphs.each do |words|
        break if remaining <= 0

        take = words.first(remaining)
        clamped << take.join(" ")
        remaining -= take.length
      end
      "#{clamped.join("\n\n")}…"
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
