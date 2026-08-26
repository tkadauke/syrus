# Class-per-action dispatch hierarchy for Story 11's named ref-movement
# actions (docs/plans/delivery-tracks-and-promotion.md), keyed by
# `.syrus.yml`'s `delivery.ref_movement_actions.<name>` block — a class
# hierarchy instead of a `case action_name` chain, mirroring
# `ExternalPrIngestions::Base.for(classification)` (see CLAUDE.md's
# enum-driven-behavior convention).
#
# Every subclass reuses an existing dispatch primitive from earlier Jobs in
# this Epic (`UpstreamExportDispatcher`, `WorkUnits::Launcher` +
# `Workflows::UpstreamExport`) rather than re-implementing ref movement —
# this layer only adds config gating (`DeliveryPolicy#ref_movement_action_*`)
# and the durable `RefMovementAction` audit row.
module RefMovementActions
  class Base
    def self.for(name)
      {
        "send_job_upstream" => RefMovementActions::SendJobUpstream,
        "submit_branch_upstream" => RefMovementActions::SubmitBranchUpstream
      }.fetch(name.to_s, RefMovementActions::Unsupported).new
    end

    # Dispatches the action (or records why it couldn't), returning a
    # persisted `RefMovementAction`. Subclasses implement `#call`, which
    # returns a Hash of attributes to persist beyond the shared
    # repository/actor/action_name fields this method always sets.
    def dispatch!(repository:, actor:, action:, source: nil, target: nil)
      config = DeliveryPolicy.for(repository: repository).ref_movement_action_config(action)

      RefMovementAction.create!(
        {
          repository: repository,
          requested_by_user: actor,
          action_name: action,
          mode: config&.mode,
          grade_phases: config&.grade_phases || []
        }.merge(
          if config&.enabled
            call(repository: repository, actor: actor, config: config, source: source, target: target)
          else
            { state: "blocked", blocked_reason: blocked_reason_for(config) }
          end
        )
      )
    end

    # `[available_boolean, blocked_reason_or_nil]` — used both by
    # `dispatch!`'s eligibility gate and by `list_ref_movement_actions` to
    # explain why an action isn't available right now, without actually
    # dispatching it. `job`/`source_branch` are only meaningful to the
    # subclasses that need them (`SendJobUpstream`/`SubmitBranchUpstream`
    # respectively) — both are accepted on every subclass so callers don't
    # need to branch on which action they're checking.
    def available?(repository:, job: nil, source_branch: nil)
      raise NotImplementedError
    end

    private

    def call(repository:, actor:, config:, source:, target:)
      raise NotImplementedError
    end

    def blocked_reason_for(config)
      config ? "#{config.name} is not enabled in delivery.ref_movement_actions" : "not configured in delivery.ref_movement_actions"
    end
  end

  class Unsupported < Base
    def dispatch!(repository:, actor:, action:, source: nil, target: nil)
      RefMovementAction.create!(
        repository: repository,
        requested_by_user: actor,
        action_name: action,
        state: "blocked",
        blocked_reason: "unsupported ref-movement action: #{action}"
      )
    end

    def available?(repository:, job: nil, source_branch: nil)
      [ false, "unsupported ref-movement action" ]
    end
  end
end
