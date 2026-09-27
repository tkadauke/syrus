module OperatorBriefing
  class BlockedDesignDocThreads
    def self.for_user(user) = new(user).threads

    def initialize(user)
      @user = user
    end

    def threads
      return DesignDocs::DesignDocThread.none unless defined?(DesignDocs::DesignDocThread)

      DesignDocs::DesignDocThread
        .joins(:design_doc)
        .merge(DesignDocs::DesignDoc.visible_to(user))
        .where(state: "open")
        .where(last_comment_is_not_by_operator_sql)
    end

    private

    attr_reader :user

    def last_comment_is_not_by_operator_sql
      sanitize_sql([
        <<~SQL.squish,
          EXISTS (
            SELECT 1
            FROM design_doc_comments latest_comment
            WHERE latest_comment.design_doc_thread_id = design_doc_threads.id
              AND latest_comment.created_at = (
                SELECT MAX(inner_comment.created_at)
                FROM design_doc_comments inner_comment
                WHERE inner_comment.design_doc_thread_id = design_doc_threads.id
              )
              AND NOT (
                latest_comment.author_kind = 'user'
                AND latest_comment.author_user_id = ?
              )
          )
        SQL
        user.id
      ])
    end

    def sanitize_sql(value)
      ActiveRecord::Base.sanitize_sql_array(value)
    end
  end
end
