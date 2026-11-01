require "digest"
require "pathname"
require "uri"

module SyrusBrowser
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = [ AgentRole::CHAT_CODING, AgentRole::WORKFLOW_VISUAL_REVIEWER ].freeze
    ALLOW_DEFAULTS = ROLES.index_with { :allow }.freeze

    class << self
      def normalize_scope(scope, context:)
        source = scope.to_h.with_indifferent_access
        source.slice(:origin, :path).stringify_keys.tap do |value|
          value["origin"] = normalized_origin(value["origin"]) if value["origin"].present?
          value["path"] = Pathname.new(value["path"].to_s).cleanpath.to_s if value["path"].present?
        end
      end

      def validate_scope(scope, context:)
        errors = []
        errors << "origin must be an allowed loopback URL" if scope["origin"].present? && !LoopbackGuard.allowed?(scope["origin"])
        errors << "path must be absolute" if scope["path"].present? && !Pathname.new(scope["path"]).absolute?
        errors
      end

      def scope_label(scope, context:)
        [ scope["origin"] || "owned browser session", scope["path"] ].compact.join(" / ")
      end

      def compare_scopes(left, right, context:)
        return :equal if left == right
        return :broader if left.empty?
        return :narrower if right.empty?
        return :disjoint unless left["origin"] == right["origin"]
        return :broader if left["path"].blank?
        return :narrower if right["path"].blank?

        :disjoint
      end

      def normalized_origin(value)
        uri = URI.parse(value.to_s)
        "#{uri.scheme.to_s.downcase}://#{uri.host.to_s.downcase}:#{uri.port}"
      rescue URI::InvalidURIError
        value.to_s
      end

      def normalize_arguments(arguments)
        source = arguments.to_h.with_indifferent_access
        source.slice(:url, :target, :start_target, :end_target, :width, :height, :text_gone, :time).stringify_keys.tap do |value|
          if source[:url].present?
            value["url"] = normalize_url(source[:url])
            userinfo = url_userinfo(source[:url])
            value["url_userinfo_sha256"] = Digest::SHA256.hexdigest(userinfo) if userinfo.present?
          end
          value["function_sha256"] = Digest::SHA256.hexdigest(source[:function].to_s) if source.key?(:function)
          if source.key?(:text) && source.key?(:target)
            value["input_text_sha256"] = Digest::SHA256.hexdigest(source[:text].to_s)
          elsif source.key?(:text)
            value["text"] = source[:text]
          end
          value["paths"] = Array(source[:paths]).map { |path| File.expand_path(path.to_s) }.sort if source.key?(:paths)
          value["data_sha256"] = Digest::SHA256.hexdigest(source[:data].to_json) if source.key?(:data)
        end
      end

      def redact_arguments(arguments)
        normalize_arguments(arguments).tap do |value|
          value["paths"] = value.fetch("paths", []).map { |path| "[PATH:#{Digest::SHA256.hexdigest(path)[0, 12]}]" } if value.key?("paths")
        end
      end

      def normalize_url(value)
        uri = URI.parse(value.to_s)
        uri.fragment = nil
        uri.user = nil
        uri.password = nil
        uri.to_s
      rescue URI::InvalidURIError
        value.to_s
      end

      def url_userinfo(value)
        URI.parse(value.to_s).userinfo.to_s
      rescue URI::InvalidURIError
        ""
      end

      def fixed_classifier(operation, effects, risk)
        ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } }
      end

      def interaction_classifier(_arguments)
        { operation: "browser.interact/action@v1", effects: %i[local_read isolated_execution], risk: :high, confidence: :uncertain }
      end
    end

    register_resource_scope(
      :browser_session, options: { hierarchy: %w[origin path] },
      normalize: method(:normalize_scope), validate: method(:validate_scope),
      label: method(:scope_label), compare: method(:compare_scopes)
    )

    def self.register(operation:, capability:, effects:, risk:, defaults: ALLOW_DEFAULTS,
      maximum_autonomy: :job, authority_durations: %i[invocation chat_session job], classifier: nil)
      register_capability(
        capability:, operation:, effects:, risk:, requestable_roles: ROLES, defaults:,
        maximum_autonomy:, authority_durations:, resource_scope: :browser_session,
        classifier: classifier || fixed_classifier(operation, effects, risk),
        fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
      )
    end

    register operation: "browser.observe/read@v1", capability: "browser.observe@v1",
      effects: %i[local_read isolated_execution], risk: :low
    register operation: "browser.navigate/open@v1", capability: "browser.navigate@v1",
      effects: %i[network_read isolated_execution], risk: :medium
    register operation: "browser.interact/action@v1", capability: "browser.interact@v1",
      effects: %i[local_read isolated_execution], risk: :high, classifier: method(:interaction_classifier)
    register operation: "browser.execute/evaluate@v1", capability: "browser.execute@v1",
      effects: %i[network_read confidential_read isolated_execution], risk: :high,
      defaults: ROLES.index_with { :ask }, maximum_autonomy: :invocation, authority_durations: %i[invocation]
    register operation: "browser.upload/file@v1", capability: "browser.upload@v1",
      effects: %i[local_read isolated_execution], risk: :high,
      defaults: ROLES.index_with { :ask }, maximum_autonomy: :invocation, authority_durations: %i[invocation]
    register operation: "browser.close/session@v1", capability: "browser.close@v1",
      effects: %i[isolated_execution], risk: :low
  end
end
