# Trigger point for `deploy.mode: continuous` — called from `after_success`
# on the landing Workflow templates (Workflows::AutoMerge,
# Workflows::MergeTrain, Workflows::ExternalPrMerge) once a Job (or, for a
# merge train, an Epic's children) has landed. Reads the repository's
# `.syrus.yml` from its default branch through GitHub (the same
# App::DeployAvailability the manual-deploy gate uses), since this can run
# on the web tier and web pods don't mount the worker's on-disk bare clone
# (see "Deploy target" in CLAUDE.md — "Web pods don't need this volume").
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
