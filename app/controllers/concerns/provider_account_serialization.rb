module ProviderAccountSerialization
  private

  def provider_accounts_json(accounts)
    accounts = accounts.to_a
    active_reference_ids = ProviderAccount.actively_referenced_ids(accounts)
    accounts.map { |account| provider_account_json(account, active_reference_ids: active_reference_ids) }
  end

  def provider_account_json(account, availability: nil, active_reference_ids: nil)
    availability ||= ::App::ProviderAvailability.for_user(Current.user, account.provider_key, provider_account: account)
    active_reference_ids ||= ProviderAccount.actively_referenced_ids([ account ])
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
      removable: !active_reference_ids.include?(account.id),
      availability: availability
    }
  end
end
