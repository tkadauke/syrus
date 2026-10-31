class Coworkers::GrantEscalation
  def self.preflight!(owner:, coworker_id:, grants:)
    coworker = Coworkers::Coworker.where(owner_user: owner).find(coworker_id)
    requested = normalize(grants)
    raise ArgumentError, "grants must not be empty" if requested.empty?

    unknown = requested.map { |entry| entry.fetch(:capability) } - Coworkers::GrantCatalog.names
    raise ArgumentError, "unknown grants: #{unknown.join(', ')}" if unknown.any?
    requested.each do |entry|
      descriptor = Coworkers::GrantCatalog.fetch(entry.fetch(:capability))
      raise ArgumentError, "scope is required for #{descriptor.name}" if descriptor.scopeable? && entry[:scope].nil?
      raise ArgumentError, "invalid scope for #{descriptor.name}" unless descriptor.valid_scope?(entry[:scope], user: owner)
      raise ArgumentError, "scope is not supported for #{descriptor.name}" if !descriptor.scopeable? && entry[:scope].present?
    end
    capabilities = requested.map { |entry| entry.fetch(:capability) }
    existing = coworker.grants.where(capability: capabilities).filter_map do |grant|
      entry = requested.find { |candidate| candidate[:capability] == grant.capability }
      grant.capability if entry[:scope].nil? || grant.scope == entry[:scope]
    end
    raise ArgumentError, "already granted: #{existing.join(', ')}" if existing.any?

    presented = requested.map { |entry| entry[:scope].nil? ? entry[:capability] : entry.stringify_keys }
    [ coworker, presented ]
  end

  def self.call(owner:, coworker_id:, grants:)
    coworker, requested = preflight!(owner: owner, coworker_id: coworker_id, grants: grants)
    Coworkers::Grant.transaction do
      normalize(requested).each do |entry|
        capability = entry.fetch(:capability)
        grant = coworker.grants.find_or_initialize_by(capability: capability)
        grant.update!(
          capability: capability,
          approval_policy: grant.approval_policy.presence || Coworkers::Create::DEFAULT_GRANTS.fetch(capability) { Coworkers::GrantCatalog.fetch(capability).maximum_policy },
          scope: entry[:scope]
        )
      end
    end
    coworker
  end

  def self.normalize(grants)
    Array(grants).map do |raw|
      if raw.respond_to?(:to_h)
        value = raw.to_h.symbolize_keys
        { capability: (value[:capability] || value[:name]).to_s, scope: value[:scope] }
      else
        { capability: raw.to_s, scope: nil }
      end
    end.uniq
  end
  private_class_method :normalize
end
