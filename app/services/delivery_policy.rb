# Answers delivery-model questions (target branch, grade phase, promotion/
# hotfix-sync posture) for a repository/job, per
# docs/plans/delivery-tracks-and-promotion.md. Workflow code should ask this
# object questions instead of reading `.syrus.yml`'s `delivery:` block or
# repository columns directly (see "Policy Objects" in the plan).
#
# `Job` has no `delivery_track` column yet (added in a later Job in the
# Delivery Tracks Epic), so every job currently resolves to the config's
# `default` track. Nothing in the runtime calls this yet — this class exists
# so later Jobs in the Epic have a stable interface to build on.
class DeliveryPolicy
  def self.for(repository:, job: nil)
    new(repository: repository, job: job)
  end

  def initialize(repository:, job: nil)
    @repository = repository
    @job = job
  end

  def job_delivery_track(job = @job)
    track_for(job).name
  end

  def job_landing_branch(job = @job)
    resolved_branch(track_for(job))
  end

  def review_grade_phase(job = @job)
    track_for(job).review_grade_phase
  end

  def landing_grade_phase(job = @job)
    track_for(job).landing_grade_phase
  end

  def branch_health_grade_phase(branch = nil)
    track_for_branch(branch).branch_health_grade_phase
  end

  def promotion_enabled?
    delivery.promotion.enabled
  end

  def promotion_mode
    delivery.promotion.mode
  end

  def hotfix_sync_enabled?
    delivery.hotfix_sync.enabled
  end

  def hotfix_sync_mode
    delivery.hotfix_sync.mode
  end

  private

  attr_reader :repository

  # Job track selection doesn't exist yet (see class comment); every job
  # resolves to the `default` track until that column lands.
  def track_for(_job)
    default_track
  end

  def track_for_branch(branch)
    return default_track if branch.blank?

    delivery.tracks.values.find { |track| resolved_branch(track) == branch } || default_track
  end

  def default_track
    delivery.tracks.fetch(SyrusYml::DEFAULT_DELIVERY_TRACK_NAME)
  end

  def resolved_branch(track)
    track.branch.presence || repository.default_branch
  end

  def delivery
    @delivery ||= config.delivery
  end

  def config
    @config ||= load_config
  end

  def load_config
    clone_path = RepositoryBareClone.path_for(repository)
    return blank_config unless clone_path.directory?

    yml_content = `git --git-dir #{clone_path.to_s.shellescape} show HEAD:.syrus.yml 2>/dev/null`
    return blank_config unless $?.success? && yml_content.present?

    SyrusYml.new(yml_content).parse
  rescue StandardError
    blank_config
  end

  def blank_config
    SyrusYml.new("").parse
  end
end
