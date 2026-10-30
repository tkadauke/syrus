class Coworkers::ProvisioningReconciler
  STALE_AFTER = 15.minutes

  def self.call(now: Time.current)
    Coworkers::ProvisioningAttempt.requiring_reconciliation(cutoff: now - STALE_AFTER).find_each do |attempt|
      attempt.update!(state: "cleanup_pending") if attempt.state == "provisioning" && attempt.expected_seeded_commit.present?
      if attempt.expected_seeded_commit.blank?
        attempt.update!(state: "cleaned", cleaned_at: now, last_error: nil)
      else
        Coworkers::ProvisioningCleanupJob.perform_later(attempt.id)
      end
    end
  end
end
