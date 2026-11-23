# frozen_string_literal: true

require "syrus/plugin/context/work_context"
require "syrus/plugin/context/repair_context"

module Syrus
  module Plugin
    module WorkPolicy
      Veto = Data.define(:reason, :message, :landing, :details) do
        def initialize(reason:, message:, landing: false, details: {})
          super(reason: reason.to_s, message: message.to_s, landing: !!landing, details: details.to_h.freeze)
        end

        def landing? = landing
      end

      VETOES = Family::ReturnContract.new(
        description: "Array<Veto> or nil",
        matcher: ->(value) { value.nil? || (value.is_a?(Array) && value.all? { |item| item.is_a?(Veto) }) },
        explicit: true
      )

      module Adapter
        WorkGate = Struct.new(:unused) do
          def self.dispatch(provider, context) = provider.work_gate(context)
        end
        SystemAlert = Struct.new(:unused) do
          def self.dispatch(provider, _context) = provider.system_alerts
        end
        RepairClassifier = Struct.new(:unused) do
          def self.dispatch(provider, context) = provider.classify_repair(context)
        end
      end
    end

    definition = Family.define(:work_policy, built_in: true) do
      shape :facet
      absorbs :work_gate, :system_alert_provider, :repair_classifier
      capability :work_gate, composition: :collect, absent: [], decline: [], tier: :provisional,
        context: Context::WorkContext, returns: WorkPolicy::VETOES
      capability :system_alerts, composition: :collect, absent: [], decline: [], tier: :provisional,
        context: Context::JobContext, returns: Array
      capability :repair_classifier, composition: :first_claim, absent: nil, decline: nil, tier: :provisional,
        context: Context::RepairContext, returns: Object
      legacy :work_gate, capability: :work_gate, adapter: WorkPolicy::Adapter::WorkGate
      legacy :system_alert_provider, capability: :system_alerts, adapter: WorkPolicy::Adapter::SystemAlert
      legacy :repair_classifier, capability: :repair_classifier, adapter: WorkPolicy::Adapter::RepairClassifier
    end

    module Families; end
    Families.const_set(:WorkPolicy, definition)
  end
end
