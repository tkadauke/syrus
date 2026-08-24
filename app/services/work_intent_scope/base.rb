module WorkIntentScope
  # Fallback for an unrecognized `scope_type`, mirroring the previous
  # case/when default: no jobs to approve, no representative job to relaunch
  # from.
  class Base
    def jobs_requiring_approval(scope_id)
      []
    end

    def representative_job(scope_id:, repository_id:, snapshot_members:)
      nil
    end
  end
end
