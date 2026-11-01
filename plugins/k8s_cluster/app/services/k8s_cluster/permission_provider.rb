module K8sCluster
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = [ AgentRole::CHAT_PLANNER, AgentRole::WORKFLOW_IMPLEMENT ].freeze
    ASK_DEFAULTS = ROLES.index_with { :ask }.freeze
    OBSERVE_DURATIONS = %i[invocation chat_session job].freeze
    SECRET_DURATIONS = %i[invocation chat_session].freeze

    class << self
      def kubernetes_scope(kind)
        {
          options: { hierarchy: %w[cluster_id namespace kind name] },
          lookup: method(:lookup_cluster),
          normalize: ->(scope, context:) { normalize_scope(scope, kind:) },
          validate: method(:validate_scope),
          label: method(:scope_label),
          compare: method(:compare_scopes)
        }
      end

      def lookup_cluster(identifier, context:)
        cluster = KubernetesCluster.find_by(id: identifier)
        return unless cluster&.agentic_access_enabled?

        credential = ClusterCredential.credential_for(cluster)
        cluster if AgenticAccess.usable_by?(cluster, context[:mcp_context], credential: credential)
      end

      def normalize_scope(scope, kind:)
        source = scope.to_h.with_indifferent_access
        value = source.slice(:cluster_id, :namespace, :kind, :name).stringify_keys
        value["cluster_id"] ||= source[:cluster] || source[:credential] if kind == :raw
        value["cluster_id"] = normalize_identifier(value["cluster_id"]) if value.key?("cluster_id")
        %w[namespace name].each { |key| value[key] = value[key].to_s if value.key?(key) }
        value["kind"] = kind.to_s
        value
      end

      def normalize_identifier(value)
        Integer(value, exception: false) || value.to_s
      end

      def validate_scope(scope, context:)
        errors = []
        errors << "namespace requires cluster_id" if scope["namespace"].present? && scope["cluster_id"].blank?
        errors << "name requires cluster_id" if scope["name"].present? && scope["cluster_id"].blank?
        errors
      end

      def scope_label(scope, context:)
        return "All Kubernetes #{scope.fetch('kind')} resources" unless scope["cluster_id"]

        cluster = KubernetesCluster.find_by(id: scope.fetch("cluster_id"))
        [ cluster&.label || "Kubernetes cluster #{scope.fetch('cluster_id')}", scope["namespace"], scope["kind"], scope["name"] ].compact.join(" / ")
      end

      def compare_scopes(left, right, context:)
        return :equal if left == right
        return :disjoint unless left["kind"] == right["kind"]

        left_path = scope_path(left)
        right_path = scope_path(right)
        return :broader if right_path.first(left_path.length) == left_path
        return :narrower if left_path.first(right_path.length) == right_path

        :disjoint
      end

      def scope_path(scope)
        [ scope["cluster_id"], scope["namespace"], scope["name"] ].compact
      end

      def normalize_arguments(arguments)
        source = arguments.to_h.with_indifferent_access
        source.slice(:cluster_id, :namespace, :name, :credential, :cluster, :kube_context).stringify_keys.tap do |value|
          value["args"] = Array(source[:args]).map(&:to_s) if source.key?(:args)
          value["replicas"] = source[:replicas] if source.key?(:replicas)
          value["cordoned"] = source[:cordoned] if source.key?(:cordoned)
        end
      end

      def redact_arguments(arguments)
        normalize_arguments(arguments).tap do |value|
          value["credential"] = "[REDACTED CREDENTIAL]" if value.key?("credential")
          value["args"] = "[REDACTED KUBECTL ARGUMENTS]" if value.key?("args")
        end
      end

      def fixed_classifier(operation, effects, risk)
        ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } }
      end
    end

    RESOURCE_KINDS = %i[cluster namespace node pod pod_logs deployment statefulset daemonset job service ingress configmap secret event persistent_volume_claim cronjob metrics raw].freeze
    RESOURCE_KINDS.each { |kind| register_resource_scope(kind, **kubernetes_scope(kind)) }

    OBSERVE_OPERATIONS = {
      "k8s.cluster/list@v1" => :cluster,
      "k8s.namespace/read@v1" => :namespace,
      "k8s.node/read@v1" => :node,
      "k8s.pod/read@v1" => :pod,
      "k8s.pod_logs/read@v1" => :pod_logs,
      "k8s.deployment/read@v1" => :deployment,
      "k8s.statefulset/read@v1" => :statefulset,
      "k8s.daemonset/read@v1" => :daemonset,
      "k8s.job/read@v1" => :job,
      "k8s.service/read@v1" => :service,
      "k8s.ingress/read@v1" => :ingress,
      "k8s.configmap/read@v1" => :configmap,
      "k8s.event/read@v1" => :event,
      "k8s.persistent_volume_claim/read@v1" => :persistent_volume_claim,
      "k8s.cronjob/read@v1" => :cronjob,
      "k8s.metrics/read@v1" => :metrics
    }.freeze

    OBSERVE_EFFECTS = %i[network_read confidential_read credential_use].freeze
    OBSERVE_OPERATIONS.each do |operation, scope|
      register_capability(
        capability: "k8s.observe@v1", operation:, effects: OBSERVE_EFFECTS,
        risk: :medium, requestable_roles: ROLES, defaults: ASK_DEFAULTS,
        maximum_autonomy: :job, authority_durations: OBSERVE_DURATIONS, resource_scope: scope,
        classifier: fixed_classifier(operation, OBSERVE_EFFECTS, :medium),
        fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
      )
    end

    register_capability(
      capability: "k8s.secret_access@v1", operation: "k8s.secret/read@v1",
      effects: %i[network_read confidential_read credential_use], risk: :high,
      requestable_roles: ROLES, defaults: ASK_DEFAULTS, maximum_autonomy: :chat_session,
      authority_durations: SECRET_DURATIONS, resource_scope: :secret,
      classifier: fixed_classifier("k8s.secret/read@v1", %i[network_read confidential_read credential_use], :high),
      fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
    )

    WORKLOAD_OPERATIONS = {
      "k8s.deployment/restart@v1" => :deployment,
      "k8s.deployment/scale@v1" => :deployment,
      "k8s.pod/delete@v1" => :pod
    }.freeze
    WORKLOAD_OPERATIONS.each do |operation, scope|
      effects = %i[credential_use external_write operational destructive]
      register_capability(
        capability: "k8s.workload_operations@v1", operation:, effects:, risk: :high,
        requestable_roles: ROLES, defaults: ASK_DEFAULTS, maximum_autonomy: :invocation,
        authority_durations: %i[invocation], resource_scope: scope,
        classifier: fixed_classifier(operation, effects, :high),
        fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
      )
    end

    register_capability(
      capability: "k8s.node_administration@v1", operation: "k8s.node/cordon@v1",
      effects: %i[credential_use external_write privilege_change operational], risk: :critical,
      requestable_roles: ROLES, defaults: ASK_DEFAULTS, maximum_autonomy: :invocation,
      authority_durations: %i[invocation], resource_scope: :node,
      classifier: fixed_classifier("k8s.node/cordon@v1", %i[credential_use external_write privilege_change operational], :critical),
      fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
    )

    register_capability(
      capability: "k8s.raw@v1", operation: "k8s.raw/execute@v1",
      effects: %i[network_read confidential_read credential_use external_write privilege_change operational destructive irreversible],
      risk: :critical, requestable_roles: ROLES, defaults: ASK_DEFAULTS,
      maximum_autonomy: :invocation, authority_durations: %i[invocation], resource_scope: :raw,
      classifier: fixed_classifier("k8s.raw/execute@v1", %i[network_read confidential_read credential_use external_write privilege_change operational destructive irreversible], :critical),
      fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
    )
  end
end
