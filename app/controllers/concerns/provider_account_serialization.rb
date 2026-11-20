module ProviderAccountSerialization
  private

  def provider_account_json(account, availability: nil)
    availability ||= ::App::ProviderAvailability.for_user(Current.user, account.provider_key, provider_account: account)
    {
      id: account.public_id,
      provider_key: account.provider_key,
      label: account.label,
      display_label: account.display_label,
      authentication_kind: account.authentication_kind,
      enabled: account.enabled,
      position: account.position,
      weight: account.weight&.to_f,
      proactive_pause_threshold: account.proactive_pause_threshold&.to_f,
      effective_proactive_pause_threshold: account.effective_proactive_pause_threshold,
      removable: !account.actively_referenced?,
      availability: availability
    }
  end
end
