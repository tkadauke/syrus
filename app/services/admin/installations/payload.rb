module Admin
  module Installations
    class Payload
      GITHUB_APP_INSTALL_BASE_URL = "https://github.com/apps".freeze

      def show
        repositories = Repository.includes(:user, :installation).order(:owner, :name).to_a
        {
          github_app_registered: AppSetting.github_app_registered?,
          github_app_slug: AppSetting.current.github_app_slug,
          pat_owner_groups: pat_owner_groups(repositories),
          repositories: repositories.map { |repository| serialize_repository(repository) }
        }
      end

      private

      def pat_owner_groups(repositories)
        repositories
          .reject(&:app_credential_active?)
          .group_by { |repository| repository.owner.downcase }
          .map do |owner, owner_repositories|
            {
              owner: owner,
              repository_count: owner_repositories.size,
              install_url: github_app_install_url_for(owner_repositories)
            }
          end
      end

      def serialize_repository(repository)
        {
          id: repository.id,
          slug: repository.slug,
          owner: repository.owner,
          name: repository.name,
          owner_user: {
            id: repository.user.id,
            email_address: repository.user.email_address,
            admin: repository.user.admin?
          },
          app_credential_active: !!repository.app_credential_active?,
          credential_mode: repository.credential_mode,
          account_login: repository.installation&.account_login || repository.owner,
          installation_removed_at: repository.installation&.removed_at,
          github_owner_id: repository.github_owner_id,
          github_repository_id: repository.github_repository_id
        }
      end

      def github_app_install_url_for(repositories)
        repos = Array(repositories).compact
        return nil unless AppSetting.github_app_registered?
        return nil if AppSetting.current.github_app_slug.blank?
        return nil if repos.empty?

        owner_id = repos.first.github_owner_id
        return nil if owner_id.blank?
        return nil unless repos.all? { |repo| repo.github_owner_id == owner_id && repo.github_repository_id.present? }

        repos = repos.uniq(&:github_repository_id)
        query = [ "target_id=#{CGI.escape(owner_id.to_s)}" ]
        repos.each do |repo|
          query << "repository_ids[]=#{CGI.escape(repo.github_repository_id.to_s)}"
        end

        "#{GITHUB_APP_INSTALL_BASE_URL}/#{CGI.escape(AppSetting.current.github_app_slug)}/installations/new/permissions?#{query.join('&')}"
      end
    end
  end
end
