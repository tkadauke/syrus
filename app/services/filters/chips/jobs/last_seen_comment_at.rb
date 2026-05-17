module Filters
  module Chips
    module Jobs
      class LastSeenCommentAt < DateColumn
        filter_name "last_seen_comment_at"
        label "Last comment"
        column :last_seen_comment_at
      end
    end
  end
end
