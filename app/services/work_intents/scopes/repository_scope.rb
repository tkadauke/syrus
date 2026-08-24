module WorkIntents
  module Scopes
    class RepositoryScope < Base
      # Repository-scoped intents (e.g. merge_train landing) have no
      # single Job whose approval gates them.
      def jobs_requiring_approval
        []
      end

      def representative_job(snapshot_members)
        snapshot_members.first || ::Job.where(repository_id: intent.repository_id).order(created_at: :desc, id: :desc).first
      end
    end
  end
end
