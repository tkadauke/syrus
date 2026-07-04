class PrCommentAttributor
  def self.call(github_handle:, job:)
    new(github_handle: github_handle, job: job).call
  end

  def initialize(github_handle:, job:)
    @github_handle = github_handle.to_s.downcase.delete_prefix("@").strip
    @job = job
  end

  def call
    return "job_owner" if owner_handle? && @github_handle == owner_handle
    return "member" if member_handles.include?(@github_handle)

    "external"
  end

  private

  def owner_handle
    @owner_handle ||= begin
      effective_owner = @job.owner_user || @job.user
      effective_owner&.github_handle.to_s.downcase.presence
    end
  end

  def owner_handle?
    owner_handle.present? && @github_handle.present?
  end

  def member_handles
    @member_handles ||= begin
      @job.repository
          .members
          .where.not(github_handle: [ nil, "" ])
          .pluck(:github_handle)
          .map { |h| h.to_s.downcase }
          .to_set
    end
  end
end
