module WorkIntentScope
  # Repository-scoped intents (e.g. "job_bundle") don't carry their member
  # job list on the WorkIntent itself -- membership is resolved from
  # artifacts at launch time (see WorkDefinitions::BuiltIns::JobBundle
  # #members_for). JobBundleDispatcher already requires every member to be
  # `approved?` before it ever creates the intent, so there is no additional
  # job list to gate on here; this inherits Base's empty/no-op behavior.
  class RepositoryScope < Base
    def representative_job(scope_id:, repository_id:, snapshot_members:)
      snapshot_members.first || ::Job.where(repository_id: repository_id).order(created_at: :desc, id: :desc).first
    end
  end
end
