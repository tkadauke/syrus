class InstallationLinker
  def self.find_for_owner(owner)
    return nil if owner.blank?

    Installation.active.find_by("lower(account_login) = ?", owner.to_s.downcase)
  end

  def self.link_repositories_for(installation)
    Repository.where("lower(owner) = ?", installation.account_login.downcase)
      .update_all(installation_id: installation.id, updated_at: Time.current)
  end

  def self.unlink_repositories_for(installation)
    Repository.where(installation_id: installation.id)
      .update_all(installation_id: nil, updated_at: Time.current)
  end
end
