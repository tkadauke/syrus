class InstallationLinker
  def self.find_for_owner(owner)
    return nil if owner.blank?

    Installation.active.find_by(account_login: owner.to_s)
  end

  def self.find_for_repository(repository)
    find_for_owner(repository.owner)&.then { |installation| installation if installation.covers_repository?(repository) }
  end

  def self.link_repositories_for(installation)
    repositories = Repository.where(owner: installation.account_login)
    covered = if installation.repository_selection == "all"
      repositories
    else
      repositories.where(github_repository_id: Array(installation.selected_repository_ids))
    end

    covered.where("installation_id IS NULL OR installation_id <> ?", installation.id)
      .update_all(installation_id: installation.id, updated_at: Time.current)
    repositories.where(installation_id: installation.id).where.not(id: covered.select(:id))
      .update_all(installation_id: nil, updated_at: Time.current)
  end

  def self.unlink_repositories_for(installation)
    Repository.where(installation_id: installation.id)
      .update_all(installation_id: nil, updated_at: Time.current)
  end
end
