class Coworkers::GrantEscalation
  def self.preflight!(owner:, coworker_id:, grants:)
    coworker = Coworkers::Coworker.where(owner_user: owner).find(coworker_id)
    requested = Array(grants).map(&:to_s).uniq
    raise ArgumentError, "grants must not be empty" if requested.empty?

    unknown = requested - Coworkers::Create::DEFAULT_GRANTS.keys
    raise ArgumentError, "unknown grants: #{unknown.join(', ')}" if unknown.any?
    existing = coworker.grants.where(capability: requested).pluck(:capability)
    raise ArgumentError, "already granted: #{existing.join(', ')}" if existing.any?

    [ coworker, requested ]
  end

  def self.call(owner:, coworker_id:, grants:)
    coworker, requested = preflight!(owner: owner, coworker_id: coworker_id, grants: grants)
    Coworkers::Grant.transaction do
      requested.each do |capability|
        coworker.grants.create!(
          capability: capability,
          approval_policy: Coworkers::Create::DEFAULT_GRANTS.fetch(capability)
        )
      end
    end
    coworker
  end
end
