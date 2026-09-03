module DesignDocs
  class DesignDocAgentRun < ApplicationRecord
    self.table_name = "design_doc_agent_runs"

    STATUSES = %w[queued running succeeded failed canceled].freeze
    ACTIVE_STATUSES = %w[queued running].freeze

    belongs_to :design_doc, class_name: "DesignDocs::DesignDoc"
    belongs_to :thread, class_name: "DesignDocs::DesignDocThread", foreign_key: :design_doc_thread_id
    belongs_to :triggering_comment, class_name: "DesignDocs::DesignDocComment"
    belongs_to :requested_by_user, class_name: "User"
    belongs_to :base_version, class_name: "DesignDocs::DesignDocVersion", optional: true

    has_one :provider_session, as: :resumable, dependent: :destroy
    has_many :comments, class_name: "DesignDocs::DesignDocComment", dependent: :nullify
    has_many :suggestions, class_name: "DesignDocs::DesignDocSuggestion", dependent: :nullify

    validates :agent_provider, presence: true, inclusion: { in: -> { User.agent_providers } }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :triggering_comment_id, uniqueness: true
    validate :thread_belongs_to_doc
    validate :triggering_comment_belongs_to_thread
    validate :base_version_belongs_to_doc

    scope :active, -> { where(status: ACTIVE_STATUSES) }
    scope :latest_first, -> { order(created_at: :desc, id: :desc) }

    def active?
      status.in?(ACTIVE_STATUSES)
    end

    private

    def thread_belongs_to_doc
      return if thread.nil? || design_doc.nil?
      return if thread.design_doc_id == design_doc_id

      errors.add(:thread, "must belong to the same design doc")
    end

    def triggering_comment_belongs_to_thread
      return if triggering_comment.nil? || thread.nil?
      return if triggering_comment.design_doc_thread_id == design_doc_thread_id

      errors.add(:triggering_comment, "must belong to the same thread")
    end

    def base_version_belongs_to_doc
      return if base_version.nil? || design_doc.nil?
      return if base_version.design_doc_id == design_doc_id

      errors.add(:base_version, "must belong to the same design doc")
    end
  end
end
