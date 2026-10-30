class Coworkers::KnownOrphanRecovery
  HANDLE = "gilfoyle"

  def self.call(owner:, remote_owner:, remote_name:, expected_sha:, remote_workspace: nil)
    raise ArgumentError, "expected_sha must be a full Git commit SHA" unless expected_sha.to_s.match?(/\A[0-9a-f]{40}\z/i)
    raise Coworkers::ProvisioningCleanup::UnsafeCleanup, "a coworker already owns @#{HANDLE}" if Coworkers::Coworker.where(handle: HANDLE).exists?

    attempt = Coworkers::ProvisioningAttempt.create_or_find_by!(
      owner_user: owner,
      idempotency_key: "known-orphan-#{HANDLE}-#{remote_owner.downcase}-#{remote_name.downcase}-#{expected_sha.downcase}"
    ) do |record|
      record.remote_owner = remote_owner
      record.remote_name = remote_name
      record.handle = HANDLE
      record.branch = "coworkers/#{HANDLE}"
      record.expected_seeded_commit = expected_sha.downcase
      record.seeded_at = Time.current
      record.state = "cleanup_pending"
    end
    Coworkers::ProvisioningCleanup.call(attempt, remote_workspace: remote_workspace)
  end
end
