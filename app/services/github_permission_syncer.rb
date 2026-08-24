
# Sibling to GithubAppInstallationSyncer: warns about drift between Syrus
# repository role tiers and real GitHub collaborator permissions instead of
# syncing installations. Never enforces or auto-corrects anything -- this is
# detection/surfacing only (see EPIC-257). GitHub remains the actual source
# of truth for commit access; this groundwork matters more once self-hosted
# git removes GitHub as a required central host.
class GithubPermissionSyncer
  # Floor tier both directions care about. Read-tier Syrus access grants no
  # mutation rights, so a read/read-only mismatch isn't a dangerous signal;
  # a GH collaborator with only read access isn't a meaningful direction-2
  # signal either (see GithubCollaboratorDiscrepancy::PERMISSIONS).
  MISMATCH_FLOOR = "write".freeze

  def initialize(client_factory: ->(repository) { GithubClient.for(repository: repository) })
    @client_factory = client_factory
  end

  def sync
    Repository.active.where.not(installation_id: nil).find_each do |repository|
      sync_repository(repository) if repository.app_credential_active?
    end
  end

  def sync_repository(repository)
    collaborators = @client_factory.call(repository).collaborator_permissions(repository.slug)
    checked_at = Time.current

    flag_membership_mismatches!(repository, collaborators, checked_at)
    record_collaborator_only_discrepancies!(repository, collaborators, checked_at)
  rescue Octokit::Error => e
    Rails.logger.warn("[GithubPermissionSyncer] #{repository.slug} sync failed: #{e.class}: #{e.message}")
  end

  private

  # Direction 1: a Syrus write/admin holder with no equivalent GitHub
  # permission -- the dangerous direction, since Syrus would let them act
  # without real commit rights. Scoped to direct RepositoryMembership rows
  # (where the flag is stored); a write/admin tier granted only through a
  # Team has no per-user row to flag here.
  def flag_membership_mismatches!(repository, collaborators, checked_at)
    by_login = collaborators.index_by { |c| c[:login].to_s.downcase }

    repository.repository_memberships.at_least(MISMATCH_FLOOR).includes(:user).find_each do |membership|
      membership.update_columns(
        github_permission_mismatch_reason: mismatch_reason_for(membership.user, by_login),
        github_permission_mismatch_checked_at: checked_at
      )
    end
  end

  def mismatch_reason_for(user, by_login)
    handle = user.github_handle.to_s.downcase
    return "no_github_handle" if handle.blank?

    collaborator = by_login[handle]
    return "not_a_github_collaborator" if collaborator.nil?

    tier_rank = RepositoryMembership::ROLE_RANK.fetch(collaborator[:permission], -1)
    return "insufficient_github_permission" if tier_rank < RepositoryMembership::ROLE_RANK.fetch(MISMATCH_FLOOR)

    nil
  end

  # Direction 2: a GitHub collaborator with write+ access and no Syrus
  # access at all. Upserts one GithubCollaboratorDiscrepancy row per
  # still-mismatched login and prunes rows that are no longer mismatched
  # (removed collaborator, downgraded permission, or Syrus access since
  # granted).
  def record_collaborator_only_discrepancies!(repository, collaborators, checked_at)
    write_plus = collaborators.select { |c| GithubCollaboratorDiscrepancy::PERMISSIONS.include?(c[:permission]) }

    kept_ids = write_plus.filter_map do |collaborator|
      login = collaborator[:login].to_s
      next if login.blank? || syrus_access_for?(repository, login)

      record = repository.github_collaborator_discrepancies.find_or_initialize_by(github_login: login)
      record.update!(github_permission: collaborator[:permission], checked_at: checked_at)
      record.id
    end

    repository.github_collaborator_discrepancies.where.not(id: kept_ids).destroy_all
  end

  def syrus_access_for?(repository, github_login)
    user = User.where("LOWER(github_handle) = ?", github_login.downcase).first
    user.present? && repository.effective_role_for(user).present?
  end
end
