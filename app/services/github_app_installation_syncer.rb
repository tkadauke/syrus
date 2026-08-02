class GithubAppInstallationSyncer
  def initialize(client: GithubAppClient, default_user: nil)
    @client = client
    @default_user = default_user
  end

  def sync
    return [] unless AppSetting.github_app_registered?

    started_at = Time.current
    AppSetting.current.update!(
      github_app_installation_sync_started_at: started_at,
      github_app_installation_sync_error_class: nil,
      github_app_installation_sync_error_message: nil
    )

    records = nil
    begin
      seen_ids = []
      records = @client.installations.map do |payload|
        attrs = normalize(payload)
        seen_ids << attrs[:github_installation_id]
        installation = Installation.find_or_initialize_by(github_installation_id: attrs[:github_installation_id])
        installation.assign_attributes(attrs.merge(user: user_for(attrs[:account_login]), removed_at: nil))
        installation.save!
        InstallationLinker.link_repositories_for(installation)
        installation
      end

      Installation.where.not(github_installation_id: seen_ids).where(removed_at: nil).find_each do |installation|
        installation.update!(removed_at: Time.current)
        InstallationLinker.unlink_repositories_for(installation)
      end

      AppSetting.current.update!(
        github_app_installation_sync_succeeded_at: Time.current,
        github_app_installation_sync_duration_ms: ((Time.current - started_at) * 1000).round,
        github_app_installation_sync_records_seen: records.size,
        github_app_installation_sync_error_class: nil,
        github_app_installation_sync_error_message: nil
      )
    rescue => e
      AppSetting.current.update!(
        github_app_installation_sync_duration_ms: ((Time.current - started_at) * 1000).round,
        github_app_installation_sync_records_seen: records&.size,
        github_app_installation_sync_error_class: e.class.name,
        github_app_installation_sync_error_message: e.message
      )
      raise
    end

    records
  end

  private

  def normalize(payload)
    hash = payload.respond_to?(:to_h) ? payload.to_h : payload
    account = hash[:account] || hash["account"] || {}
    {
      github_installation_id: hash[:id] || hash["id"],
      account_login: account[:login] || account["login"],
      account_id: account[:id] || account["id"],
      account_type: account[:type] || account["type"],
      installed_at: installed_at(hash)
    }
  end

  def installed_at(hash)
    value = hash[:created_at] || hash["created_at"] || Time.current
    value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) ? value : Time.zone.parse(value.to_s)
  end

  def user_for(account_login)
    Repository.where("lower(owner) = ?", account_login.to_s.downcase).includes(:user).first&.user ||
      @default_user ||
      User.where(admin: true).order(:id).first ||
      User.order(:id).first
  end
end
