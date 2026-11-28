# frozen_string_literal: true

module Syrus
  module Plugin
    # Manifest declarations: plugin contributions that are *data*, not provider
    # classes. A plugin names workflow kinds, a Job origin key, a slug prefix, a
    # problem namespace, a repository-configuration key, forwarded step
    # environment names, or a worker capability token in its manifest, and the
    # manifest can be listed, validated and diffed without loading a line of
    # plugin code.
    #
    # Behavior that cannot be data (looking up a record, parsing a config
    # envelope, building a probe command) is referenced by constant *name* and
    # resolved only at the moment it is used. Core reads the declarations through
    # the legacy bridge in {PluginRegistry}: each declaration is adapted into the
    # provider shape the legacy extension point always had, so core call sites
    # never see two registration forms and a plugin that still registers a
    # provider class under `provides` keeps working until it migrates.
    #
    # Validation happens twice, with different consequences:
    #
    # * At manifest parse time (the DSL call in `syrus_plugin`) a malformed
    #   declaration raises {InvalidDeclaration} with a message naming the plugin,
    #   the declaration and the field. The plugin loader isolates that raise, so
    #   an external plugin built against an older or newer core becomes a
    #   plugin-health finding and the host keeps booting.
    # * At registration time (`PluginRegistry.register`) the same structural
    #   check runs again for registrations that do not come through the DSL, and
    #   the checks that need core constants (worker capability dimensions) run
    #   there too. Those become `validation_errors` on the manifest.
    module Declarations
      class InvalidDeclaration < ArgumentError; end

      POINTS = %i[
        workflow_kinds job_origin slug_type problem_provider
        repository_configuration step_environment worker_capability_probe
      ].freeze

      CONSTANT_NAME = /\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/
      IDENTIFIER = /\A[a-z][a-z0-9_]*\z/
      ENV_NAME = /\A[A-Z][A-Z0-9_]*\z/

      TRIGGER_KEYS = %i[
        kind template label style retry_label feedback_kind runtime_role owns_job_lifecycle
        coding_takeover_hold escalation_urgency visual_review_instructions_artifact builds_from_base
      ].freeze
      TRIGGER_REQUIRED = %i[kind template label style].freeze
      STEP_KEYS = %i[
        kind handler label style agentic required_mcp_tools fail_policy reconcile_strategy
        skip_if_artifact triggers_auto_approval repair_semantics advance_handler agent_role
        resource_profile_step_kinds resource_profile_grader_name_key resource_profile_fallback_step_kinds
        resource_profile_default_overrides waits_for_terminal_step_kind review_gate panel_capable
        reviewer_target_required runtime_inserted outcome_override_collector_kind placement_policy
        worker_checks
      ].freeze
      STEP_REQUIRED = %i[kind handler label style agentic].freeze
      JOB_KEYS = %i[kind infrastructure issueless investigable classifiable].freeze
      PROBLEM_KEYS = %i[code scope retryable default_remediation failure_codes issue_kinds label].freeze
      PROBLEM_REQUIRED = %i[code scope retryable default_remediation].freeze
      PROBE_KEYS = %i[dimension token diagnostic_key].freeze

      # Keys whose symbol-ness is part of the entry contract. Declarations carry
      # strings (a manifest is data), and the generated provider restores them.
      SYMBOL_FIELDS = {
        trigger_kinds: %i[feedback_kind],
        step_kinds: %i[fail_policy reconcile_strategy repair_semantics],
        problem_kinds: %i[scope default_remediation]
      }.freeze

      module_function

      # Normalizes one declaration for `point`, returning an immutable entry.
      # Raises {InvalidDeclaration} naming `plugin` and the offending field.
      def normalize!(plugin, point, attrs)
        point = point.to_sym
        unless POINTS.include?(point)
          raise InvalidDeclaration,
            "#{plugin}: unknown manifest declaration #{point.inspect}; declarations are #{POINTS.join(', ')}"
        end

        attrs = check_hash!(plugin, point, attrs, "declaration").transform_keys(&:to_sym)
        deep_freeze(public_send(:"normalize_#{point}", plugin, attrs))
      end

      # Re-validates stored declarations (for registrations that bypass the DSL)
      # and returns `[declarations, errors]`; an invalid entry is dropped so one
      # bad declaration cannot take the rest of a plugin down with it.
      def sanitize(plugin, declarations)
        errors = []
        clean = {}
        (declarations || {}).each do |point, entries|
          Array(entries).each do |entry|
            (clean[point.to_sym] ||= []) << normalize!(plugin, point, entry)
          rescue InvalidDeclaration => e
            errors << e.message
          end
        end
        [ clean.transform_values { |entries| entries.freeze }.freeze, errors ]
      end

      # Checks that need core constants and therefore cannot run while a plugin
      # entry file is being loaded.
      def semantic_errors(plugin, declarations)
        Array(declarations[:worker_capability_probe]).filter_map do |entry|
          next if TargetGraph::ExecutionCapabilities::DIMENSIONS.include?(entry[:dimension])

          "#{plugin}: worker_capability_probe declares unknown dimension #{entry[:dimension].inspect}; " \
            "valid dimensions are #{TargetGraph::ExecutionCapabilities::DIMENSIONS.join(', ')}"
        end
      end

      # A plugin that declares a point as data *and* still registers a provider
      # class for it is doubled until it finishes migrating.
      def duplicates_for(manifests)
        manifests.flat_map do |manifest|
          POINTS.filter_map do |point|
            next unless manifest.declarations[point].present? && Array(manifest.provides[point]).any?

            { plugin: manifest.name, extension_point: point }
          end
        end
      end

      # The legacy-shaped providers a manifest's declarations stand for.
      def providers_for_manifest(manifest, point)
        entries = manifest.declarations[point.to_sym]
        return [] if entries.blank?

        Providers.for(manifest.name, point.to_sym, entries)
      end

      def normalize_workflow_kinds(plugin, attrs)
        reject_unknown!(plugin, :workflow_kinds, attrs, %i[trigger_kinds step_kinds job_kinds work_definitions])
        {
          trigger_kinds: kind_entries!(plugin, :trigger_kinds, attrs[:trigger_kinds], TRIGGER_KEYS, TRIGGER_REQUIRED),
          step_kinds: kind_entries!(plugin, :step_kinds, attrs[:step_kinds], STEP_KEYS, STEP_REQUIRED),
          job_kinds: kind_entries!(plugin, :job_kinds, attrs[:job_kinds], JOB_KEYS, %i[kind]),
          work_definitions: constant_names!(plugin, :workflow_kinds, :work_definitions, attrs[:work_definitions])
        }
      end

      def normalize_job_origin(plugin, attrs)
        reject_unknown!(plugin, :job_origin, attrs, %i[key provider icon])
        {
          key: identifier!(plugin, :job_origin, :key, attrs[:key]),
          provider: optional_constant!(plugin, :job_origin, :provider, attrs[:provider]),
          icon: optional_string!(plugin, :job_origin, :icon, attrs[:icon])
        }
      end

      def normalize_slug_type(plugin, attrs)
        reject_unknown!(plugin, :slug_type, attrs, %i[
          prefix display_label resolver client_path preview_available copyable linkable linkifies_generated_text
        ])
        prefix = attrs[:prefix]
        unless prefix.is_a?(String) && prefix.match?(/\A[A-Z][A-Z0-9]*\z/)
          raise InvalidDeclaration, "#{plugin}: slug_type prefix must be upper-case letters and digits, got #{prefix.inspect}"
        end
        client_path = optional_string!(plugin, :slug_type, :client_path, attrs[:client_path])
        if client_path && !client_path.start_with?("/")
          raise InvalidDeclaration, "#{plugin}: slug_type #{prefix} client_path must start with \"/\", got #{client_path.inspect}"
        end
        {
          prefix: prefix,
          display_label: required_string!(plugin, :slug_type, :display_label, attrs[:display_label]),
          resolver: required_constant!(plugin, :slug_type, :resolver, attrs[:resolver]),
          client_path: client_path,
          preview_available: boolean!(plugin, :slug_type, :preview_available, attrs[:preview_available], false),
          copyable: boolean!(plugin, :slug_type, :copyable, attrs[:copyable], true),
          linkable: boolean!(plugin, :slug_type, :linkable, attrs[:linkable], true),
          linkifies_generated_text: boolean!(plugin, :slug_type, :linkifies_generated_text, attrs[:linkifies_generated_text], true)
        }
      end

      def normalize_problem_provider(plugin, attrs)
        reject_unknown!(plugin, :problem_provider, attrs, %i[namespace kinds])
        namespace = attrs[:namespace]
        unless namespace.is_a?(String) && namespace.match?(IDENTIFIER)
          raise InvalidDeclaration, "#{plugin}: problem_provider namespace must match #{IDENTIFIER.inspect}, got #{namespace.inspect}"
        end
        kinds = kind_entries!(plugin, :problem_kinds, attrs[:kinds], PROBLEM_KEYS, PROBLEM_REQUIRED, key: :code)
        kinds.each do |entry|
          next if entry[:code].start_with?("#{namespace}.")

          raise InvalidDeclaration,
            "#{plugin}: problem_provider code #{entry[:code].inspect} must start with its namespace #{"#{namespace}.".inspect}"
        end
        { namespace: namespace, kinds: kinds }
      end

      def normalize_repository_configuration(plugin, attrs)
        reject_unknown!(plugin, :repository_configuration, attrs, %i[key schema_version legacy_keys provider])
        key = attrs[:key]
        unless key.is_a?(String) && key.match?(/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/)
          raise InvalidDeclaration, "#{plugin}: repository_configuration key must be namespaced like \"owner.name\", got #{key.inspect}"
        end
        unless key.start_with?("#{plugin}.")
          raise InvalidDeclaration, "#{plugin}: repository_configuration key #{key.inspect} must use the owner namespace #{"#{plugin}.".inspect}"
        end
        version = attrs.fetch(:schema_version, 1)
        unless version.is_a?(Integer) && version.positive?
          raise InvalidDeclaration, "#{plugin}: repository_configuration #{key} schema_version must be a positive integer, got #{version.inspect}"
        end
        legacy = Array(attrs[:legacy_keys])
        unless legacy.all? { |legacy_key| legacy_key.is_a?(String) && legacy_key.match?(IDENTIFIER) }
          raise InvalidDeclaration, "#{plugin}: repository_configuration #{key} legacy_keys must be identifiers, got #{legacy.inspect}"
        end
        {
          key: key, schema_version: version, legacy_keys: legacy,
          provider: required_constant!(plugin, :repository_configuration, :provider, attrs[:provider])
        }
      end

      def normalize_step_environment(plugin, attrs)
        reject_unknown!(plugin, :step_environment, attrs, %i[forwarded_env_keys extra_env])
        keys = Array(attrs[:forwarded_env_keys])
        bad = keys.reject { |name| name.is_a?(String) && name.match?(ENV_NAME) }
        unless bad.empty?
          raise InvalidDeclaration, "#{plugin}: step_environment forwarded_env_keys must be ENV names like \"SCCACHE_BUCKET\", got #{bad.inspect}"
        end
        extra = optional_constant!(plugin, :step_environment, :extra_env, attrs[:extra_env])
        if keys.empty? && extra.nil?
          raise InvalidDeclaration, "#{plugin}: step_environment must declare forwarded_env_keys or an extra_env class"
        end
        { forwarded_env_keys: keys.uniq, extra_env: extra }
      end

      def normalize_worker_capability_probe(plugin, attrs)
        reject_unknown!(plugin, :worker_capability_probe, attrs, PROBE_KEYS + %i[probe])
        token = attrs[:token]
        unless token.is_a?(String) && token.match?(IDENTIFIER)
          raise InvalidDeclaration, "#{plugin}: worker_capability_probe token must match #{IDENTIFIER.inspect}, got #{token.inspect}"
        end
        dimension = attrs[:dimension]
        unless dimension.is_a?(String) && dimension.match?(IDENTIFIER)
          raise InvalidDeclaration, "#{plugin}: worker_capability_probe #{token} dimension must be an identifier, got #{dimension.inspect}"
        end
        {
          dimension: dimension, token: token,
          diagnostic_key: optional_string!(plugin, :worker_capability_probe, :diagnostic_key, attrs[:diagnostic_key]) || token,
          probe: required_constant!(plugin, :worker_capability_probe, :probe, attrs[:probe])
        }
      end

      def kind_entries!(plugin, list, entries, allowed, required, key: :kind)
        return [] if entries.nil?

        unless entries.is_a?(Array)
          raise InvalidDeclaration, "#{plugin}: #{list} must be an array of hashes"
        end
        seen = Set.new
        entries.map do |entry|
          entry = check_hash!(plugin, list, entry, "entry").transform_keys(&:to_sym)
          name = entry[key]
          unless name.is_a?(String) && name.match?(key == :code ? /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_.]*)+\z/ : IDENTIFIER)
            raise InvalidDeclaration, "#{plugin}: #{list} entry #{key} must be a lowercase identifier string, got #{name.inspect}"
          end
          unknown = entry.keys - allowed
          unless unknown.empty?
            raise InvalidDeclaration, "#{plugin}: #{list} #{name.inspect} has unknown key(s) #{unknown.join(', ')}; allowed: #{allowed.join(', ')}"
          end
          missing = required.reject { |field| entry.key?(field) }
          unless missing.empty?
            raise InvalidDeclaration, "#{plugin}: #{list} #{name.inspect} is missing required key(s) #{missing.join(', ')}"
          end
          raise InvalidDeclaration, "#{plugin}: #{list} declares #{name.inspect} more than once" unless seen.add?(name)

          entry.each { |field, value| check_data!(plugin, "#{list} #{name.inspect} #{field}", value) }
          entry
        end
      end

      def constant_names!(plugin, point, field, values)
        Array(values).map { |value| required_constant!(plugin, point, field, value) }
      end

      def required_constant!(plugin, point, field, value)
        return value if value.is_a?(String) && value.match?(CONSTANT_NAME)

        raise InvalidDeclaration,
          "#{plugin}: #{point} #{field} must be a constant name string like \"MyPlugin::Thing\", got #{value.inspect}"
      end

      def optional_constant!(plugin, point, field, value)
        value.nil? ? nil : required_constant!(plugin, point, field, value)
      end

      def identifier!(plugin, point, field, value)
        return value if value.is_a?(String) && value.match?(IDENTIFIER)

        raise InvalidDeclaration, "#{plugin}: #{point} #{field} must match #{IDENTIFIER.inspect}, got #{value.inspect}"
      end

      def required_string!(plugin, point, field, value)
        return value if value.is_a?(String) && !value.strip.empty?

        raise InvalidDeclaration, "#{plugin}: #{point} #{field} must be a non-empty string, got #{value.inspect}"
      end

      def optional_string!(plugin, point, field, value)
        value.nil? ? nil : required_string!(plugin, point, field, value)
      end

      def boolean!(plugin, point, field, value, default)
        return default if value.nil?
        return value if [ true, false ].include?(value)

        raise InvalidDeclaration, "#{plugin}: #{point} #{field} must be true or false, got #{value.inspect}"
      end

      def reject_unknown!(plugin, point, attrs, allowed)
        unknown = attrs.keys - allowed
        return if unknown.empty?

        raise InvalidDeclaration,
          "#{plugin}: #{point} has unknown key(s) #{unknown.join(', ')}; allowed: #{allowed.join(', ')}"
      end

      def check_hash!(plugin, point, value, what)
        return value if value.is_a?(Hash)

        raise InvalidDeclaration, "#{plugin}: #{point} #{what} must be a hash, got #{value.class}"
      end

      # A manifest is data: scalars, arrays and string-keyed hashes only. A
      # class, proc or other object would make the manifest depend on plugin code
      # being loaded, which is exactly what a declaration exists to avoid.
      def check_data!(plugin, label, value)
        case value
        when nil, true, false, Integer, Float, String, Symbol then nil
        when Array then value.each { |item| check_data!(plugin, label, item) }
        when Hash
          value.each do |key, item|
            raise InvalidDeclaration, "#{plugin}: #{label} has a non-string key #{key.inspect}" unless key.is_a?(String) || key.is_a?(Symbol)

            check_data!(plugin, label, item)
          end
        else
          raise InvalidDeclaration,
            "#{plugin}: #{label} must be plain data (string, number, boolean, array or hash), got #{value.class}; " \
            "name behavior by constant string instead"
        end
      end

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
        when Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end
  end
end
