module WorkIntents
  module Scopes
    class JobScope < Base
      def jobs_requiring_approval
        ::Job.where(id: intent.scope_id).to_a
      end

      def representative_job(snapshot_members)
        ::Job.find_by(id: intent.scope_id)
      end
    end
  end
end
