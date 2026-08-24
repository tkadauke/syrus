module WorkIntentScope
  class JobScope < Base
    def jobs_requiring_approval(scope_id)
      ::Job.where(id: scope_id).to_a
    end

    def representative_job(scope_id:, repository_id:, snapshot_members:)
      ::Job.find_by(id: scope_id)
    end
  end
end
