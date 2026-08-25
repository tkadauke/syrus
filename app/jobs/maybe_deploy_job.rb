# Continuous-deploy auto-trigger, enqueued by DeployContinuousTrigger from
# `after_success` on the landing Workflow templates. Mirrors
# MainGraderWorkflowJob's debounce pattern: a per-repository concurrency
# limit plus an in-perform re-check, rather than a bespoke lock.
class MaybeDeployJob < ApplicationJob
  queue_as :control_plane

  limits_concurrency to: 1, key: ->(repository_id, *) { "deploy:#{repository_id}" }

  def perform(repository_id)
    repository = Repository.find_by(id: repository_id)
    return unless repository
    return if repository.archived?

    deploy_config = App::DeployAvailability.deploy_config(repository)
    return unless deploy_config&.mode == "continuous"

    # A merge landing while another deploy is already in flight is a
    # no-op here, not a reschedule: rescheduling on top of an unknown
    # in-flight duration would stack up duplicate pending jobs. The
    # min_interval_minutes throttle below is what guarantees a burst of
    # merges still converges on exactly one deploy of the latest HEAD.
    return if active_deploy_workflow?(repository)

    if (wait_until = throttled_until(repository, deploy_config))
      MaybeDeployJob.set(wait_until: wait_until).perform_later(repository_id)
      return
    end

    launch_deploy!(repository)
  end

  private

  def active_deploy_workflow?(repository)
    Workflow.joins(:job)
      .where(trigger_kind: "deploy", jobs: { repository_id: repository.id })
      .where(state: %w[queued running])
      .exists?
  end

  # Never silently drop a throttled trigger: reschedule for the earliest
  # allowed time instead of dropping it, so a merge that lands mid-throttle
  # with no subsequent merge still gets deployed once the window opens.
  def throttled_until(repository, deploy_config)
    interval = deploy_config.min_interval_minutes
    return nil unless interval&.positive?

    last_finished_at = latest_deploy_finished_at(repository)
    return nil unless last_finished_at

    earliest_allowed = last_finished_at + interval.minutes
    earliest_allowed if earliest_allowed.future?
  end

  def latest_deploy_finished_at(repository)
    Workflow.joins(:job)
      .where(trigger_kind: "deploy", jobs: { repository_id: repository.id })
      .where.not(finished_at: nil)
      .maximum(:finished_at)
  end

  def launch_deploy!(repository)
    user = repository.user
    return unless user

    sha = current_default_branch_sha(repository)
    return if sha.blank?

    Job.transaction do
      job = Job.create!(
        user: user,
        repository: repository,
        kind: "deploy",
        issue_title: "deploy:#{sha}",
        issue_number: nil
      )

      workflow = WorkUnits::Launcher.instantiate(
        kind: "deploy",
        job: job,
        artifacts: { "deploy_sha" => sha }
      )

      WorkUnits::Launcher.start!(workflow)
    end
  end

  def current_default_branch_sha(repository)
    GithubClient
      .for(repository: repository, user: repository.user)
      .branch_head_sha(repository.slug, repository.default_branch)
      .to_s
      .presence
  rescue StandardError => e
    Rails.logger.warn(
      "[MaybeDeployJob] could not resolve #{repository.slug}@#{repository.default_branch} HEAD: #{e.class}: #{e.message}"
    )
    nil
  end
end
