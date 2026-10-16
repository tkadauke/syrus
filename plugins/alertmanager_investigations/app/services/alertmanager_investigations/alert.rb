require "digest"

module AlertmanagerInvestigations
  Alert = Data.define(:payload, :host_label) do
    RUNBOOK_KEYS = %w[runbook_url runbook runbookURL].freeze
    HOST_FALLBACK_LABELS = %w[instance host node kubernetes_node pod].freeze

    def fingerprint
      payload["fingerprint"].presence || Digest::SHA256.hexdigest(payload.to_json)
    end

    def labels
      payload["labels"].is_a?(Hash) ? payload["labels"] : {}
    end

    def annotations
      payload["annotations"].is_a?(Hash) ? payload["annotations"] : {}
    end

    def actionable?
      state = payload.dig("status", "state").to_s.strip
      state.blank? || state == "active"
    end

    def runbook_url
      RUNBOOK_KEYS.filter_map { |key| annotations[key].to_s.strip.presence }.first
    end

    def host
      ([ host_label ] + HOST_FALLBACK_LABELS).compact_blank.uniq
        .filter_map { |key| labels[key].to_s.strip.presence }
        .first
    end

    def canonical_host
      self.class.canonicalize_host(host)
    end

    def self.canonicalize_host(host)
      value = host.to_s.strip.downcase
      bracketed = value.match(/\A\[(.+)\](?::\d+)?\z/)
      return bracketed[1] if bracketed
      return value unless value.count(":") == 1

      value.sub(/:\d+\z/, "")
    end

    def alert_name
      labels["alertname"].to_s.presence || "Alertmanager alert"
    end
  end
end
