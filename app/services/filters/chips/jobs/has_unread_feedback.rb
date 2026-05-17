module Filters
  module Chips
    module Jobs
      # "last_seen_comment_at" is set when the poller picks up a new
      # comment; "last_feedback_addressed_at" is bumped after the
      # agent's pr_comment workflow lands. Unread = the comment is
      # newer than the last addressed-at (or addressed-at is nil).
      class HasUnreadFeedback < Base
        filter_name "has_unread_feedback"
        label "Has unread feedback"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          unread = Job.where.not(last_seen_comment_at: nil)
                      .where("last_feedback_addressed_at IS NULL OR last_seen_comment_at > last_feedback_addressed_at")
                      .select(:id)
          case op
          when :is_true  then scope.where(id: unread)
          when :is_false then scope.where.not(id: unread)
          else unsupported_op!
          end
        end
      end
    end
  end
end
