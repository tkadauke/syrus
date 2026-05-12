module CredentialModesHelper
  GITHUB_APP_INSTALL_BASE_URL = "https://github.com/apps".freeze

  def github_app_install_url_for(repositories)
    repos = Array(repositories).compact
    return nil unless AppSetting.github_app_registered?
    return nil if AppSetting.current.github_app_slug.blank?
    return nil if repos.empty?

    owner_id = repos.first.github_owner_id
    return nil if owner_id.blank?
    return nil unless repos.all? { |repo| repo.github_owner_id == owner_id && repo.github_repository_id.present? }

    query = [ "target_id=#{CGI.escape(owner_id.to_s)}" ]
    repos.each do |repo|
      query << "repository_ids[]=#{CGI.escape(repo.github_repository_id.to_s)}"
    end

    "#{GITHUB_APP_INSTALL_BASE_URL}/#{CGI.escape(AppSetting.current.github_app_slug)}/installations/new/permissions?#{query.join('&')}"
  end

  def credential_mode_pill(record)
    mode = record.respond_to?(:credential_mode) ? record.credential_mode : "pat"
    if mode == "app"
      colored_pill("App", classes: "bg-emerald-100 text-emerald-700")
    else
      colored_pill("PAT", classes: "bg-amber-100 text-amber-800")
    end
  end
end
