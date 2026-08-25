# Trigger point for `deploy.mode: continuous` — called from `after_success`
# on the landing Workflow templates (Workflows::AutoMerge,
# Workflows::MergeTrain, Workflows::ExternalPrMerge) once a Job (or, for a
# merge train, an Epic's children) has landed. Reads the repository's
# `.syrus.yml` straight off its local bare clone (the same read
# App::DeployAvailability already uses for the manual-deploy gate) so this
# check costs no GitHub API call and no workspace.
#
# All the actual debounce/concurrency/throttle decisions live in
# MaybeDeployJob; this class only decides whether to enqueue one at all.
class DeployContinuousTrigger
  def self.after_landing!(repository)
    return unless repository

    deploy_config = App::DeployAvailability.deploy_config(repository)
    return unless deploy_config&.mode == "continuous"

    MaybeDeployJob.perform_later(repository.id)
  end
end
