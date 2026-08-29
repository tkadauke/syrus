module DesignDocs
  class DesignDocVersion < ApplicationRecord
    self.table_name = "design_doc_versions"

    ACTOR_KINDS = %w[user agent system].freeze

    belongs_to :design_doc, class_name: "DesignDocs::DesignDoc"
    belongs_to :actor_user, class_name: "User", optional: true
    belongs_to :provenance, polymorphic: true, optional: true

    has_many :anchors, class_name: "DesignDocs::DesignDocAnchor", dependent: :nullify

    before_validation :normalize_markdown
    before_update :prevent_update

    validates :markdown, presence: true
    validates :version_number, numericality: { only_integer: true, greater_than: 0 }
    validates :version_number, uniqueness: { scope: :design_doc_id }
    validates :actor_kind, presence: true, inclusion: { in: ACTOR_KINDS }
    validates :actor_user, presence: true, if: :user_actor?

    def user_actor?
      actor_kind == "user"
    end

    private

    def normalize_markdown
      self.markdown = markdown.to_s
    end

    def prevent_update
      raise ActiveRecord::ReadOnlyRecord, "Design doc versions are append-only"
    end
  end
end
