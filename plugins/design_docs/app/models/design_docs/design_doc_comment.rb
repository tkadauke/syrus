module DesignDocs
  class DesignDocComment < ApplicationRecord
    self.table_name = "design_doc_comments"

    AUTHOR_KINDS = %w[user agent system].freeze

    belongs_to :thread, class_name: "DesignDocs::DesignDocThread", foreign_key: :design_doc_thread_id
    belongs_to :author_user, class_name: "User", optional: true

    before_validation :normalize_body

    validates :body, presence: true
    validates :author_kind, presence: true, inclusion: { in: AUTHOR_KINDS }
    validates :author_user, presence: true, if: :user_author?

    def user_author?
      author_kind == "user"
    end

    private

    def normalize_body
      self.body = body.to_s.strip
    end
  end
end
