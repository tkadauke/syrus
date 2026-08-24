class GithubCollaboratorDiscrepancy < ApplicationRecord
  # GitHub-side collaborators with write+ access and no corresponding
  # Syrus access at all -- see GithubPermissionSyncer. write/admin only;
  # a plain read-tier collaborator is not worth flagging.
  PERMISSIONS = %w[write admin].freeze

  belongs_to :repository

  validates :github_login, presence: true, uniqueness: { scope: :repository_id }
  validates :github_permission, inclusion: { in: PERMISSIONS }
end
