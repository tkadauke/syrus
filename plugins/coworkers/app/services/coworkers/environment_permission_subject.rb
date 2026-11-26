module Coworkers
  # Immutable input to environment lifecycle authorization. Keeping the whole
  # lifecycle subject in one contract prevents callers from authorizing a
  # coworker and later applying that decision to a different revision, image,
  # or set of running executions.
  EnvironmentPermissionSubject = Data.define(
    :coworker_id, :owner_user_id, :environment_id, :revision_id,
    :source_digest, :base_digest, :image_digest, :policy_result,
    :risk_deltas, :affected_execution_ids, :reason, :administrator_repair
  ) do
    def initialize(coworker_id:, owner_user_id:, environment_id: nil, revision_id: nil,
      source_digest: nil, base_digest: nil, image_digest: nil, policy_result: nil,
      risk_deltas: {}, affected_execution_ids: [], reason: nil, administrator_repair: false)
      super(
        coworker_id: Integer(coworker_id), owner_user_id: Integer(owner_user_id),
        environment_id: environment_id && Integer(environment_id),
        revision_id: revision_id && Integer(revision_id), source_digest: source_digest&.to_s,
        base_digest: base_digest&.to_s, image_digest: image_digest&.to_s,
        policy_result: policy_result&.to_s,
        risk_deltas: risk_deltas.to_h.stringify_keys.sort.to_h.freeze,
        affected_execution_ids: Array(affected_execution_ids).map { |id| Integer(id) }.uniq.sort.freeze,
        reason: reason&.to_s, administrator_repair: administrator_repair == true
      )
    end

    def permission_arguments = to_h.transform_keys(&:to_s)
  end
end
