class Coworkers::GrantEscalation
  def self.preflight!(owner:, coworker_id:, grants:)
    coworker = Coworkers::Coworker.where(owner_user: owner).find(coworker_id)
    requested = Array(grants).map(&:to_s).uniq
    raise ArgumentError, "grants must not be empty" if requested.empty?

    unknown = requested - Coworkers::GrantCatalog.names
    raise ArgumentError, "unknown grants: #{unknown.join(', ')}" if unknown.any?
    requested.each { |capability| Coworkers::PrivilegedGrantGate.ensure_available!(Coworkers::GrantCatalog.fetch(capability)) }
    existing = coworker.permission_rules.entries.filter_map do |entry|
      entry[:capability] if requested.include?(entry[:capability]) && entry[:approval_policy] != "off"
    end
    raise ArgumentError, "already granted: #{existing.join(', ')}" if existing.any?

    [ coworker, requested ]
  end

  def self.call(owner:, coworker_id:, grants:)
    coworker, requested = preflight!(owner: owner, coworker_id: coworker_id, grants: grants)
    PermissionRule.transaction do
      requested.each do |capability|
        coworker.permission_rules.update!(
          capability:, actor: owner,
          approval_policy: Coworkers::Create::DEFAULT_GRANTS.fetch(capability) { Coworkers::GrantCatalog.fetch(capability).maximum_policy },
          provenance: { "coworker_permission_escalation" => true }
        )
      end
    end
    coworker
  end
end
