module WorkIntents
  module Scopes
    class EpicScope < Base
      def jobs_requiring_approval
        ::Job.where(epic_id: intent.scope_id).where.not(state: "closed").to_a
      end

      def representative_job(snapshot_members)
        snapshot_members.last || ::Job.where(epic_id: intent.scope_id).order(:id).last
      end
    end
  end
end
