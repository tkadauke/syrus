module WorkIntentScope
  class EpicScope < Base
    def jobs_requiring_approval(scope_id)
      ::Job.where(epic_id: scope_id).where.not(state: "closed").to_a
    end

    def representative_job(scope_id:, repository_id:, snapshot_members:)
      snapshot_members.last || ::Job.where(epic_id: scope_id).order(:id).last
    end
  end
end
