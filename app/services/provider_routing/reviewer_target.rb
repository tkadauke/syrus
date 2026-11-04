module ProviderRouting
  class ReviewerTarget
    ResolutionError = Class.new(StandardError)
    Missing = Class.new(ResolutionError)
    PluginUnavailable = Class.new(ResolutionError)
    Invalid = Class.new(ResolutionError)

    Target = Data.define(:type, :reference, :display_snapshot, :record) do
      def to_h
        { "type" => type, "reference" => reference, "display_snapshot" => display_snapshot }
      end

      def pinned_h
        to_h.merge("record_type" => record.class.polymorphic_name, "record_id" => record.id)
      end
    end

    REVIEW_STEP_KINDS = %w[adversarial_review security_review coworker_review].freeze

    def self.resolve!(definition:, user:, repository:)
      attributes = definition.to_h.deep_stringify_keys
      type = attributes["type"].to_s
      reference = attributes["reference"].to_s
      raise Invalid, "reviewer target type and reference are required" if type.blank? || reference.blank?

      provider = providers.find { |candidate| candidate.reviewer_target_type == type }
      raise PluginUnavailable, "reviewer target provider #{type.inspect} is unavailable" unless provider

      record = provider.resolve_reviewer_target(reference: reference, user: user, repository: repository)
      raise Missing, "reviewer target #{reference.inspect} is unavailable" unless record

      Target.new(
        type: type,
        reference: reference,
        display_snapshot: provider.reviewer_target_snapshot(record).deep_stringify_keys,
        record: record
      )
    end

    def self.options(user:, repository: nil)
      providers.flat_map { |provider| Array(provider.reviewer_target_options(user: user, repository: repository)) }
    end

    def self.providers
      Syrus::PluginRegistry.providers_for(:reviewer_target_provider)
    end
    private_class_method :providers
  end
end
