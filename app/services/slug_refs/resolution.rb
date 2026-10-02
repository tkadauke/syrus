module SlugRefs
  class Resolution
    attr_reader :provider, :numeric_id, :record, :error

    def self.accessible(provider:, id:, record:)
      new(provider: provider, numeric_id: id, record: record)
    end

    def self.inaccessible(provider:, id:)
      new(provider: provider, numeric_id: id)
    end

    def self.malformed(provider: nil)
      new(provider: provider, error: "malformed")
    end

    def self.unknown
      new(error: "unknown")
    end

    def initialize(provider: nil, numeric_id: nil, record: nil, error: nil)
      @provider = provider
      @numeric_id = numeric_id
      @record = record
      @error = error
    end

    def known_type?
      provider.present?
    end

    def malformed?
      error == "malformed"
    end

    def unknown?
      error == "unknown"
    end

    def accessible?
      record.present?
    end

    def canonical_slug
      return nil unless provider && numeric_id

      provider.canonical_slug(numeric_id)
    end

    def to_h
      base = {
        canonical_slug: canonical_slug,
        type: provider&.type_key,
        prefix: provider&.prefix,
        display_label: provider&.display_label,
        numeric_id: numeric_id,
        accessible: accessible?,
        web_path: accessible? ? provider.web_path(record) : nil,
        api_preview_path: accessible? ? provider.api_preview_path(record) : nil,
        copyable: provider ? provider.copyable? : false,
        preview_available: provider ? provider.preview_available? : false,
        linkifies_generated_text: provider ? provider.linkifies_generated_text? : false,
        mobile_interaction_hints: provider ? provider.mobile_interaction_hints : {}
      }

      base
    end
  end
end
