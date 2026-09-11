class GithubApiUsageRollup < ApplicationRecord
  belongs_to :installation, optional: true
  belongs_to :user, optional: true
  belongs_to :repository, optional: true

  validates :bucket_started_at, :auth_source, :credential_key, :repository_key, :operation, :last_seen_at, presence: true

  def self.record!(auth_source:, installation:, user:, repository:, repo_slug:, operation:, headers:, status:, rate_limited:)
    now = Time.current
    bucket = now.beginning_of_hour
    resource = headers&.[]("x-ratelimit-resource").presence || "unknown"
    attrs = {
      bucket_started_at: bucket,
      auth_source: auth_source.to_s,
      credential_key: credential_key(auth_source: auth_source, installation: installation, user: user),
      installation_id: installation&.id,
      user_id: user&.id,
      repository_id: repository&.id,
      repository_key: repository&.id ? "repository:#{repository.id}" : "slug:#{repo_slug.presence || "unknown"}",
      operation: operation.to_s.presence || "unknown",
      resource: resource
    }

    rollup = nil
    begin
      rollup = find_or_create_by!(attrs) do |record|
        record.repo_slug = repo_slug
        record.last_seen_at = now
      end
    rescue ActiveRecord::RecordNotUnique
      rollup = find_by!(attrs)
    end

    rollup.with_lock do
      rollup.repo_slug = repo_slug.presence || rollup.repo_slug
      rollup.request_count += 1
      rollup.rate_limited_count += 1 if rate_limited
      rollup.last_status = status if status
      rollup.last_remaining = headers&.[]("x-ratelimit-remaining")&.to_i
      rollup.last_limit = headers&.[]("x-ratelimit-limit")&.to_i
      reset_epoch = headers&.[]("x-ratelimit-reset").to_i
      rollup.last_reset_at = Time.at(reset_epoch) if reset_epoch.positive?
      rollup.last_seen_at = now
      rollup.save!
    end
  rescue => e
    Rails.logger.warn("[GithubApiUsageRollup] record failed: #{e.class}: #{e.message}")
  end

  def self.credential_key(auth_source:, installation:, user:)
    return "installation:#{installation.id}" if auth_source.to_s == "installation" && installation
    return "user:#{user.id}" if user

    "unknown"
  end
end
