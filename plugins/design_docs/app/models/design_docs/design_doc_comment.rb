module DesignDocs
  class DesignDocComment < ApplicationRecord
    self.table_name = "design_doc_comments"

    AUTHOR_KINDS = %w[user agent system].freeze

    belongs_to :thread, class_name: "DesignDocs::DesignDocThread", foreign_key: :design_doc_thread_id
    belongs_to :author_user, class_name: "User", optional: true
    belongs_to :agent_run, class_name: "DesignDocs::DesignDocAgentRun", foreign_key: :design_doc_agent_run_id, optional: true

    before_validation :normalize_body
    after_create :request_agent_run_for_new_mention
    after_update :request_agent_run_for_newly_introduced_mention, if: :saved_change_to_body?

    validates :body, presence: true
    validates :author_kind, presence: true, inclusion: { in: AUTHOR_KINDS }
    validates :author_user, presence: true, if: :user_author?
    validate :agent_run_belongs_to_thread

    def user_author?
      author_kind == "user"
    end

    private

    def normalize_body
      self.body = body.to_s.strip
    end

    def request_agent_run_for_new_mention
      request_agent_run(previous_body: nil)
    end

    def request_agent_run_for_newly_introduced_mention
      request_agent_run(previous_body: saved_change_to_body&.first)
    end

    def request_agent_run(previous_body:)
      return unless user_author? && author_user
      return unless DesignDocs::AgentMentionDetector.mentioned?(body, previous_body: previous_body)

      DesignDocs::RequestAgentRun.call(comment: self, user: author_user)
    rescue Pundit::NotAuthorizedError, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[DesignDocs::DesignDocComment] skipped @syrus agent run for comment #{id}: #{e.class}: #{e.message}")
    end

    def agent_run_belongs_to_thread
      return if agent_run.nil? || thread.nil?
      return if agent_run.design_doc_thread_id == design_doc_thread_id

      errors.add(:agent_run, "must belong to the same thread")
    end
  end
end
