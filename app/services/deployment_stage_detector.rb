class DeploymentStageDetector
  REACHED_RELATIONS = %i[ahead identical].freeze

  def initialize(repository:, deployment_stages:, jobs:, content: nil)
    @repository = repository
    @deployment_stages = Array(deployment_stages)
    @jobs = Array(jobs)
    @content = content || RepositoryContent.for(repository)
    @refs_cache = {}
    @relation_cache = {}
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
      revision = content.resolve(stage.tag, max_age: 0)
      RepositoryContent::Ref.new(name: stage.tag, revision_id: revision.id, observed_at: revision.observed_at)
    else
      refs_for(stage.tag_pattern).first
    end
  rescue RepositoryContent::UnknownRevision
    nil
  end

  def refs_for(pattern)
    @refs_cache[pattern] ||= content.refs(pattern: pattern, max_age: 0)
  end

  def reached_stage?(landed_sha, tag)
    return true if tag.revision_id == landed_sha

    @relation_cache[[ landed_sha, tag.revision_id ]] ||= REACHED_RELATIONS.include?(
      content.relation(base: content.revision(landed_sha), head: content.revision(tag.revision_id))
    )
  end

  def record_stage!(job, stage, tag)
    JobDeploymentStageStatus.create!(
      job: job,
      stage_name: stage.name,
      reached_at: Time.current,
      tag_sha: tag.revision_id
    )
    true
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    false
  end

  attr_reader :content
end
