module App
  module Presentation
    # Registry + factory resolving a ChatPendingAction to its presenter.
    # Mirrors the top-level PendingActions execution registry
    # (app/services/pending_actions.rb): each presenter self-registers via
    # `action_key`, so adding a key to ChatPendingAction::ACTIONS/ACTION_TYPES
    # is paired with a presenter registration instead of a new branch in a
    # shared label/detail switch. `Fallback` covers any key without a
    # registered presenter, preserving the pre-refactor default behavior.
    #
    # Unlike the execution registry, one presenter class can own several
    # action keys (see JobScopedAction, StaticLabelAction, etc.), so a key
    # can't be turned back into its class name by convention alone. PRESENTERS
    # lists every presenter class once so `.for` can force each one to load
    # (and self-register) before consulting REGISTRY.
    module PendingActions
      REGISTRY = {}

      PRESENTERS = %w[
        JobScopedAction
        StaticLabelAction
        AdminIdentifierAction
        BranchDivergenceRecoveryAction
        OverrideLandingBlockerOnce
        CloseJobSuccessfully
        SubmitChatFeedback
        CompleteImplementStep
        EmergencyLand
        ReconcileJobState
        ForceStateTransition
        CancelStaleWork
        ReenqueueWork
        RerunCiRepair
        MarkCiRepairNoop
        CreateRepoDocument
        DeleteRepoDocument
        DeleteDesignDoc
        ReopenEpicAndAttachJob
        SubmitCodingChanges
        RepairProviderCircuitEvidence
        ClearProviderCircuit
        WakeProviderAdmission
        ScheduleRecurring
      ].freeze

      def self.register(key, klass)
        REGISTRY[key.to_s] = klass
      end

      def self.key_for(action)
        (action.action.presence || action.action_type).to_s
      end

      def self.for(action)
        load_presenters!
        (REGISTRY[key_for(action)] || Fallback).new(action)
      end

      def self.load_presenters!
        return if @loaded

        PRESENTERS.each { |name| const_get(name) }
        @loaded = true
      end
    end
  end
end
