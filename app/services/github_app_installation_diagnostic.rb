class GithubAppInstallationDiagnostic
  GITHUB_APP_INSTALL_BASE_URL = "https://github.com/apps".freeze

  def initialize(slug: nil)
    @slug = slug.to_s.strip.presence
  end

  def show
    repositories = scoped_repositories
    {
      global: global_state,
      latest_sync: latest_sync,
      installations: installation_rows(repositories),
      repositories: repositories.map { |repository| repository_state(repository) },
      recommended_next_action: recommended_next_action(repositories)
    }
  end

  private

  attr_reader :slug

  def scoped_repositories
    scope = Repository.active.includes(:user, :installation, repository_memberships: [ :user, :installation ]).order(:owner, :name)
    return scope.to_a if slug.blank?

    owner, name = slug.split("/", 2)
    return [] if owner.blank? || name.blank?

    scope.where("lower(owner) = ? AND lower(name) = ?", owner.downcase, name.downcase).to_a
  end

  def global_state
    settings = AppSetting.current
    {
      app_id_present: settings.github_app_id.present?,
      slug_present: settings.github_app_slug.present?,
      private_key_present: settings.github_app_private_key_pem.present?,
      registered_at: settings.github_app_registered_at&.iso8601,
      registered: settings.github_app_registered?,
      jwt_usable: jwt_result.fetch(:usable),
      jwt_error_class: jwt_result.fetch(:error_class),
      jwt_error_message: jwt_result.fetch(:error_message)
    }
  end

  def jwt_result
    @jwt_result ||= begin
      settings = AppSetting.current
      if settings.github_app_id.blank? || settings.github_app_private_key_pem.blank?
        { usable: false, error_class: nil, error_message: "App id and private key are required to sign a JWT." }
      else
        GithubAppClient.app_jwt(settings)
        { usable: true, error_class: nil, error_message: nil }
      end
    rescue => e
      { usable: false, error_class: e.class.name, error_message: e.message }
    end
  end

  def latest_sync
    settings = AppSetting.current
    {
      last_attempted_at: settings.github_app_installation_sync_started_at&.iso8601,
      last_successful_at: settings.github_app_installation_sync_succeeded_at&.iso8601,
      duration_ms: settings.github_app_installation_sync_duration_ms,
      records_seen: settings.github_app_installation_sync_records_seen,
      error_class: settings.github_app_installation_sync_error_class,
      error_message: settings.github_app_installation_sync_error_message
    }
  end

  def installation_rows(repositories)
    owners = repositories.map { |repository| repository.owner.downcase }.uniq
    Installation.where("lower(account_login) IN (?)", owners.presence || [ nil ])
      .order(Arel.sql("lower(account_login) ASC"), :github_installation_id)
      .map { |installation| installation_state(installation) }
  end

  def installation_state(installation)
    {
      id: installation.id,
      account_login: installation.account_login,
      account_id: installation.account_id,
      account_type: installation.account_type,
      github_installation_id: installation.github_installation_id,
      installed_at: installation.installed_at&.iso8601,
      removed_at: installation.removed_at&.iso8601,
      active: installation.active?
    }
  end

  def repository_state(repository)
    inactive_reason = repository_inactive_reason(repository)
    {
      id: repository.id,
      slug: repository.slug,
      owner: repository.owner,
      name: repository.name,
      github_owner_id: repository.github_owner_id,
      github_repository_id: repository.github_repository_id,
      installation_id: repository.installation_id,
      app_credential_active: !!repository.app_credential_active?,
      app_credential_inactive_reason: inactive_reason,
      credential_mode: repository.credential_mode,
      scoped_install_url: github_app_install_url_for([ repository ]),
      install_url_missing_reason: install_url_missing_reason([ repository ]),
      repository_installation: repository.installation && installation_state(repository.installation),
      membership_installations: membership_states(repository),
      recommended_next_action: recommended_next_action([ repository ])
    }
  end

  def membership_states(repository)
    repository.repository_memberships.map do |membership|
      installation = membership.installation
      {
        user_id: membership.user_id,
        user_email: membership.user&.email_address,
        role: membership.role,
        installation_id: membership.installation_id,
        effective_client_installation_id: (installation&.active? ? installation.id : repository.installation_id),
        installation: installation && installation_state(installation)
      }
    end
  end

  def repository_inactive_reason(repository)
    settings = AppSetting.current
    return nil if repository.app_credential_active?
    return "github_app_not_registered" unless settings.github_app_registered?
    return "github_app_private_key_missing" if settings.github_app_private_key_pem.blank?
    return "linked_installation_removed" if repository.installation&.removed_at.present?
    return "removed_installation_for_owner" if removed_installations_for_owner(repository.owner).any?
    return "github_repository_ids_missing" if repository.github_owner_id.blank? || repository.github_repository_id.blank?
    return "repository_installation_link_missing" if repository.installation_id.blank? && active_installations_for_owner(repository.owner).any?
    return "owner_mismatch_or_not_installed" if Installation.exists?

    "no_installations_synced"
  end

  def recommended_next_action(repositories)
    return "refresh_installations" unless AppSetting.github_app_registered?
    return "refresh_installations" if repositories.empty?
    return "relink_repository_to_existing_active_installation" if repositories.any? { |repo| repo.installation_id.blank? && active_installations_for_owner(repo.owner).any? }
    return "reinstall_app_for_owner_or_repo" if repositories.any? { |repo| repo.installation&.removed_at.present? || removed_installations_for_owner(repo.owner).any? }
    return "reselect_repository_to_capture_github_ids" if repositories.any? { |repo| install_url_missing_reason([ repo ]).present? }
    return "refresh_installations" if latest_sync.fetch(:last_attempted_at).blank?
    return "refresh_installations" if latest_sync.fetch(:error_class).present?
    return "fallback_to_pat" unless repositories.any?(&:app_credential_active?)

    "none"
  end

  def active_installations_for_owner(owner)
    Installation.active.where("lower(account_login) = ?", owner.to_s.downcase)
  end

  def removed_installations_for_owner(owner)
    Installation.where.not(removed_at: nil).where("lower(account_login) = ?", owner.to_s.downcase)
  end

  def github_app_install_url_for(repositories)
    reason = install_url_missing_reason(repositories)
    return nil if reason

    repos = repositories.uniq(&:github_repository_id)
    query = [ "target_id=#{CGI.escape(repos.first.github_owner_id.to_s)}" ]
    repos.each { |repo| query << "repository_ids[]=#{CGI.escape(repo.github_repository_id.to_s)}" }
    "#{GITHUB_APP_INSTALL_BASE_URL}/#{CGI.escape(AppSetting.current.github_app_slug)}/installations/new/permissions?#{query.join('&')}"
  end

  def install_url_missing_reason(repositories)
    repos = Array(repositories).compact
    settings = AppSetting.current
    return "github_app_not_registered" unless settings.github_app_registered?
    return "github_app_slug_missing" if settings.github_app_slug.blank?
    return "repository_missing" if repos.empty?
    return "github_owner_id_missing" if repos.first.github_owner_id.blank?
    return "github_repository_id_missing" unless repos.all? { |repo| repo.github_repository_id.present? }
    return "mixed_github_owner_ids" unless repos.all? { |repo| repo.github_owner_id == repos.first.github_owner_id }

    nil
  end
end
