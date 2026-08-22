class DeploymentStageDetector
  REACHED_COMPARE_STATUSES = %w[ahead identical].freeze

  def initialize(repository:, deployment_stages:, jobs:, client: nil)
    @repository = repository
    @deployment_stages = Array(deployment_stages)
    @jobs = Array(jobs)
    @client = client
    @tag_cache = nil
    @compare_cache = {}
  end

  def call
    return 0 if deployment_stages.empty? || jobs.empty?

    recorded = 0
    jobs.each do |job|
      next if job.landed_sha.blank?

      pending_stages_for(job).each do |stage|
        tag = resolve_tag(stage)
        next unless tag

        next unless reached_stage?(job.landed_sha, tag)

        recorded += 1 if record_stage!(job, stage, tag)
      end
    end

    recorded
  end

  private

  attr_reader :repository, :deployment_stages, :jobs

  def pending_stages_for(job)
    detected = detected_stage_names_by_job_id[job.id] || []
    deployment_stages.reject { |stage| detected.include?(stage.name) }
  end

  def detected_stage_names_by_job_id
    @detected_stage_names_by_job_id ||= JobDeploymentStageStatus
      .where(job_id: jobs.map(&:id))
      .pluck(:job_id, :stage_name)
      .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(job_id, stage_name), hash|
        hash[job_id] << stage_name
      end
  end

  def resolve_tag(stage)
    if stage.tag.present?
      tags_by_name[stage.tag]
    else
      all_tags.find { |tag| File.fnmatch?(stage.tag_pattern, tag[:name], File::FNM_PATHNAME) }
    end
  end

  def tags_by_name
    @tags_by_name ||= all_tags.index_by { |tag| tag[:name] }
  end

  def all_tags
    @tag_cache ||= github_client.list_tags(repository.slug)
  end

  def reached_stage?(landed_sha, tag)
    return true if tag[:sha].present? && tag[:sha] == landed_sha

    @compare_cache[[ landed_sha, tag[:name] ]] ||= begin
      compare = github_client.compare_commits(repository.slug, landed_sha, tag[:name])
      REACHED_COMPARE_STATUSES.include?(compare[:status])
    end
  end

  def record_stage!(job, stage, tag)
    JobDeploymentStageStatus.create!(
      job: job,
      stage_name: stage.name,
      reached_at: Time.current,
      tag_sha: tag[:sha]
    )
    true
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    false
  end

  def github_client
    @client ||= GithubClient.for(repository: repository, user: repository.user)
  end
end
