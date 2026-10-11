module JobNeedsAttention
  extend ActiveSupport::Concern

  def set_needs_attention!(reason:)
    now = Time.current
    update!(
      needs_attention: true,
      needs_attention_reason: reason,
      needs_attention_since: needs_attention_since || now
    )
  end

  def clear_needs_attention!(reason: nil)
    return unless needs_attention?
    return if reason.present? && needs_attention_reason != reason

    update!(
      needs_attention: false,
      needs_attention_reason: nil,
      needs_attention_since: nil
    )
  end

  # --- grace period ----------------------------------------------------------

  def start_grace_period!(duration:)
    expires_at = Time.current + duration
    update!(grace_period_expires_at: expires_at)
    GracePeriodExpiryJob.set(wait_until: expires_at).perform_later(id)
  end

  def cancel_grace_period!
    return unless grace_period_expires_at.present?

    update!(grace_period_expires_at: nil)
  end

  def in_grace_period?
    grace_period_expires_at.present? && grace_period_expires_at > Time.current
  end

  def grace_period_expired?
    grace_period_expires_at.present? && grace_period_expires_at <= Time.current
  end
end
