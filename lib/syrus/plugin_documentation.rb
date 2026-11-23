# frozen_string_literal: true

module Syrus
  class PluginDocumentation
    HOST_API_PATH = Rails.root.join("docs/engineering/conventions/plugins/host-api.md")
    PLUGIN_SPEC_PATH = Rails.root.join("docs/engineering/conventions/plugins/plugin-spec.md")
    FAMILY_REFERENCE_ROOT = Rails.root.join("docs/engineering/conventions/plugins/families")
    GENERATE_COMMAND = "bin/generate-plugin-docs"

    MANIFEST_DESCRIPTIONS = {
      display_name: "Human-readable plugin name.", display_name_i18n_key: "Translation key for the display name.",
      description: "Short fallback description.", description_i18n_key: "Translation key for the short description.",
      long_description: "Detailed fallback description.", long_description_i18n_key: "Translation key for the detailed description.",
      homepage: "Plugin homepage URL.", icon_url: "Plugin-owned icon path or URL.", author: "Plugin author.",
      category: "Catalog category.", version: "Plugin version; normally read from the gem.",
      default_enabled: "Whether a new installation enables the plugin.", disableable: "Whether an operator may disable it.",
      experimental: "Marks an instance-local experimental plugin.", home_queue: "Default Solid Queue queue.",
      tick_interval: "Optional control-plane tick interval.", prepare_priority: "Ordering priority for prepare contributions.",
      depends_on: "Required plugin names.", optionally_depends_on: "Optional plugin names.", conflicts_with: "Mutually exclusive plugin names.",
      roles: "Process roles in which the plugin may load.",
      hosts: "Qualified extension points this plugin exposes to other plugins.", config_schema: "Operator setting declarations.",
      cli_commands: "Non-interactive server-backed CLI commands: path, summary, handler, arguments, and flags.",
      provides: "Extension-point classes, or one family provider with implements/provisional capabilities and an optional key.", route: "Plugin-owned Rails route (verb, path, controller).",
      frontend: "Prebuilt frontend entry and i18n locale-file patterns.", events: "Domain events published by the plugin.",
      link: "One plugin navigation link.", links: "A list of plugin navigation links.",
      credential_type_names: "Credential type names declared for discovery.", credential_types: "Credential type metadata declarations.",
      toolkit: "Toolkit-family tools, permission declarations, run context, credential probes, and secret extractors.",
      surface: "Surface-family pages, tabs, slots, artifact and preview renderers, and filter registrations.",
      chat_integration: "ChatIntegration-family payload, prompt, media, lifecycle, identity, status, and mention contributions.",
      review_contributions: "Review-family gates, reviewer targets, review context and presentation, post-implementation review, diff annotation, and adjudicator contributions.",
      policy: "Policy-family Job visibility restrictions and repository filters (fail-closed composition).",
      agent_runtime: "AgentRuntime service-family agent and chat providers.",
      execution_backend: "ExecutionBackend service-family command execution backends.",
      runtime_session: "RuntimeSession service-family long-lived runtime session providers.",
      source_host: "SourceHost service-family source-control, input-source, repository-content, and git-transport services.",
      speech_to_text: "SpeechToText service-family transcription providers.",
      lifecycle: "Lifecycle-family plugin callbacks and domain-event subscribers (broadcast; failures are isolated per hook).",
      data_policy: "DataPolicy-family retention policies, purge contributors, and retained preview-panel decisions (every contributor participates; failures are reported).",
      while_enabled: "Reversible installation effects active only while enabled.", metrics: "Plugin-owned metric declarations.",
      always: "Reversible effects retained after a previously enabled plugin is disabled.",
      suggests_enabling: "Evidence callback for suggesting a disabled plugin.", on_boot: "Idempotent process-level boot callback.",
      declare: "Generic form of the data declarations below: `declare :slug_type, prefix: ...`.",
      workflow_kinds: "Data declaration of plugin-owned Job, Workflow trigger, Step kinds and WorkDefinition constant names; no provider class.",
      job_origin: "Data declaration of a Job origin key, with an optional constant name for label, link and prompt behavior.",
      slug_type: "Data declaration of a canonical identifier prefix, label and link template, with a resolver constant name for record lookup.",
      problem_provider: "Data declaration of a problem namespace and its stable problem kinds.",
      repository_configuration: "Data declaration of a namespaced `.syrus.yml` key, schema version and legacy keys, with a parser constant name.",
      step_environment: "Data declaration of ENV names forwarded into step subprocesses, with an optional per-scope extra_env constant name.",
      worker_capability_probe: "Data declaration of the worker capability dimension and token a probe may report, with a probe constant name."
    }.freeze

    class << self
      def host_api(apis: Host.apis, surface: PluginHostSurface.new)
        public_api = apis.sort_by(&:name).map { |api| host_entry(api) }.join("\n\n")
        legacy_api = surface.legacy_entries.sort_by(&:name).map { |entry| "- `#{entry.name}`" }.join("\n")
        <<~MARKDOWN
          <!-- Generated by #{GENERATE_COMMAND}; do not edit. -->
          # Plugin host API

          Public core APIs supported for external plugins. Use these `Syrus::Host`
          facades instead of their underlying core constants. Unlisted facades and
          unlisted members are internal.

          ## Public APIs

          #{public_api}

          ## Legacy compatibility APIs

          These core constants are recognized by the compatibility scanner because
          bundled plugins still reference them. They are not supported for new or
          external plugins. Migrate to a public `Syrus::Host` facade instead.

          #{legacy_api}
        MARKDOWN
      end

      def plugin_spec(apis: Host.apis, surface: PluginHostSurface.new)
        fields = PluginApi::Definition::MANIFEST_KEYS.sort.map do |key|
          "- `#{key}` — #{MANIFEST_DESCRIPTIONS.fetch(key)}"
        end.join("\n")
        extensions = PluginRegistry::EXTENSION_POINTS.sort.map do |point|
          interface = PluginRegistry::INTERFACE_FOR.fetch(point).call
          description = PluginRegistry::EXTENSION_POINT_DESCRIPTIONS.fetch(point)
          "- `#{point}` — #{description} Implement `#{interface.name}`; interface contract: `#{interface_path(interface)}`."
        end.join("\n")
        public_api = apis.sort_by(&:name).map do |api|
          members = api.members.sort.map { |name| "`#{name}`" }.join(", ")
          "- `#{api.name}` (since #{api.since}) — #{api.summary}#{members.empty? ? '' : " Supported members: #{members}."}"
        end.join("\n")
        families = Plugin::Family.all.sort_by(&:name).map do |family|
          capabilities = family.capabilities.values.sort_by(&:name).map do |capability|
            "`#{capability.name}` (#{capability.tier}, #{capability.composition}, #{capability.return_contract.description})"
          end.join(", ")
          "- `#{family.name}` (#{family.shape}; required core: #{family.required_core.map { |name| "`#{name}`" }.join(', ')}) — #{capabilities}"
        end.join("\n").presence || "No capability families are currently defined."

        with_recorded_size(<<~MARKDOWN)
          <!-- Generated by #{GENERATE_COMMAND}; do not edit. -->
          # Syrus plugin specification

          Paste this whole file into an LLM context when authoring a plugin.

          ## Package and manifest

          A plugin is a gem loaded as trusted in-process code and requires a Syrus restart after installation or upgrade. Its gemspec must set a requirement string such as `metadata["requires_syrus"] = ">= 0.1.16"`; Syrus parses it as a `Gem::Requirement`. The requirement must cover the oldest tested Syrus release and be no lower than the newest host API `since` version the plugin uses. The entry file extends `Syrus::PluginApi` and declares one `syrus_plugin` block. Accepted keys:

          #{fields}

          `frontend` declares the prebuilt browser entry plus `i18n` patterns for locale JSON. English (`en`) is required; user-visible copy must also ship German (`de`) and Latin (`la`). `cli_commands` handlers subclass `Syrus::Plugin::CliCommandHandler`; commands are validated, non-interactive, and server-backed.

          ## Extension points

          #{extensions}

          ## Capability families

          Declare one family at a time with `provides family_name: "Provider::Class", implements: %i[stable_capability], provisional: %i[experimental_capability]`. Providers implement only the capabilities they declare. Run the generated shared examples named `a valid <family> provider` from `syrus/plugin/test_kit`, passing literal plugin and provider strings plus call and decline contexts. The kit derives the full capability list from that exact manifest declaration, and the literal identifiers let isolated and sharded suite runs verify coverage from source.

          #{families}

          ## Public host surface

          #{public_api}

          The compatibility scanner also recognizes #{surface.legacy_entries.size} legacy core constants used by bundled plugins. They are not public APIs and must not be used by new or external plugins; use only the `Syrus::Host` facades listed above.

          ## Packaging and testing

          Keep all plugin code, migrations, frontend assets, locales, and documentation inside the gem. Do not add third-party runtime gems: depend only on Syrus and its shipped stack. Tests are required for every behavior change; include contract tests for each extension and package/relocation coverage. Plugin code is trusted in-process code, not a sandbox.

          ## Avoid

          - Calling unlisted core constants or members, or any `legacy` API.
          - Reaching into another plugin without a declared dependency and extension point.
          - Shipping source-only frontend code instead of the declared prebuilt bundle and locales.
          - Registering irreversible work in lifecycle hooks or assuming disable/uninstall removes owned data.
          - Adding chat MCP tools without an explicit tool-card rendering status.

          Size: {{SIZE}} bytes (UTF-8, including this line).
        MARKDOWN
      end

      def write!
        HOST_API_PATH.write(host_api)
        PLUGIN_SPEC_PATH.write(plugin_spec)
        FileUtils.mkdir_p(FAMILY_REFERENCE_ROOT)
        references = family_references
        FAMILY_REFERENCE_ROOT.glob("*.md").each do |path|
          path.delete unless references.key?(path.basename(".md").to_s.to_sym)
        end
        references.each do |name, body|
          FAMILY_REFERENCE_ROOT.join("#{name}.md").write(body)
        end
      end

      def family_references(definitions: Plugin::Family.all)
        definitions.sort_by(&:name).to_h { |family| [ family.name, family_reference(family) ] }
      end

      def family_reference(family)
        capabilities = family.capabilities.values.sort_by(&:name).map do |capability|
          lines = [
            "- Composition: `#{capability.composition}`",
            "- Absent result: `#{capability.absent.inspect}`",
            "- Provider decline: `#{capability.decline.inspect}`"
          ]
          unless capability.failure == capability.decline
            failure = capability.failure.respond_to?(:call) ? capability.failure.call : capability.failure
            lines << "- Provider failure (fail-closed): `#{failure.inspect}`"
          end
          lines += [
            "- Tier: `#{capability.tier}`",
            "- Context: `#{capability.context.respond_to?(:name) ? capability.context.name : capability.context}`",
            "- Return shape: `#{capability.return_contract.description}`"
          ]
          "### `#{capability.name}`\n\n#{lines.join("\n")}\n"
        end.join("\n")
        compatibility_notes = if family.name == :ecosystem
          <<~MD
            ## Migration from legacy extension points

            Ecosystem is shipped and the former per-operation extension points are no longer registered. External language plugins must replace their legacy `provides` entries with one family declaration and implement context-based capability methods.

            Before:

            ```ruby
            provides prepare_detector: "AcmeLang::PrepareDetector"
            ```

            After:

            ```ruby
            provides ecosystem: "AcmeLang::Ecosystem", implements: %i[detect_prepare]
            ```

            `AcmeLang::Ecosystem.detect_prepare(context)` receives a `RepoContext` and returns `EcosystemPreparePlan` values. Declare stable capabilities in `implements:` and provisional capabilities in `provisional:`.

            `affected_tests` remains provisional because it has one in-tree implementation. `parse_ci_log`, `review_file_patterns`, and `target_graph` remain provisional because core calls them but no bundled plugin implements them yet; the contract kit supplies reference fakes until real implementations prove the contracts.

            For keyed capabilities, the absent behavior applies when no provider matches the requested key and raises `Dispatch::MissingKey`; a matched provider's decline value is separate.
          MD
        elsif family.name == :toolkit
          <<~MD
            ## Migration from legacy extension points

            Toolkit replaces the separate MCP tool-set, permission-provider,
            run-context, and credential-registration declarations. Bundled plugins
            use the manifest helper, which creates a named family provider and
            keeps referenced plugin constants reload-safe.

            Before:

            ```ruby
            provides mcp_tool_set: "Acme::WorkflowTools",
                     permission_provider: "Acme::Permissions"
            ```

            After:

            ```ruby
            toolkit workflow_tools: "Acme::WorkflowTools",
                    permissions: "Acme::Permissions"
            ```

            Family dispatch preserves provider priority and isolates failures, so
            one broken tool-set provider does not prevent the remaining tools from
            being advertised. `run_context` remains provisional because only one
            bundled plugin implements it; every other toolkit capability has at
            least two independent bundled implementations and generated contracts.
          MD
        elsif family.name == :surface
          <<~MD
            ## Migration from legacy extension points

            Surface keeps manifest-visible contribution data separate from the
            frontend runtime registry. The manifest helper records which pages,
            tabs, slots, renderers, and filters a plugin contributes while the
            browser bundle still registers React components through
            `registerPluginContribution`.

            Before:

            ```ruby
            provides sidebar_page: "Acme::SidebarPages",
                     ui_slot: "Acme::UiSlots"
            ```

            After:

            ```ruby
            surface sidebar_pages: "Acme::SidebarPages",
                    ui_slots: "Acme::UiSlots"
            ```

            Use `filter_subjects:` and `filter_chips:` instead of lifecycle
            effects that call `Filters.register_subject` or
            `Filters.register_chips`. Provider constants are resolved only when
            enabled contributions are dispatched, so catalog reads do not load
            plugin application code and disabled plugins remain lazy.

            `preview_panel_viewers` is provisional because no bundled plugin
            implements it yet. Every other Surface capability has at least two
            independent bundled implementations and generated contract coverage.
          MD
        elsif family.name == :chat_integration
          <<~MD
            ## Migration from legacy extension points

            ChatIntegration groups the contributions consulted while building or
            executing an interactive chat turn. The manifest helper keeps provider
            constants lazy and dispatcher failures isolated from the rest of the turn.

            Before:

            ```ruby
            provides chat_payload_contributor: "Acme::Payload",
                     chat_prompt_injector: "Acme::Prompt"
            ```

            After:

            ```ruby
            chat_integration payload_contributors: "Acme::Payload",
                             prompt_injectors: "Acme::Prompt"
            ```

            All capabilities remain provisional. Payload, prompt, media, and turn
            orientation have multiple in-tree implementations, but the family
            currently returns the established behavior providers while their
            multi-operation interfaces are decomposed. Lifecycle, status, identity,
            and mention capabilities each have only one independent implementation.
            Generated contract examples still cover every bundled declaration.
          MD
        elsif family.name == :review
          <<~MD
            ## Migration from legacy extension points

            The Review family keeps the `external_reviewer` service capability and
            also absorbs the review-step extension points: `review_gate`,
            `reviewer_target_provider`, `review_context_contributor`,
            `review_presentation_contributor`, `post_implementation_review_provider`,
            `diff_review_annotation_provider`, and `adjudicator`.

            Before:

            ```ruby
            provides review_gate: "Acme::ReviewGate",
                     review_context_contributor: "Acme::ReviewContext"
            ```

            After:

            ```ruby
            review_contributions review_gates: "Acme::ReviewGate",
                                 review_context_contributors: "Acme::ReviewContext"
            ```

            Review gates are evidence about one exact implementation HEAD and fail
            closed. Migrating the provider list changed no gate semantics: core
            still invokes each gate operation through `PluginInvocation`, a
            provider whose operation fails declines with the same value as before,
            and the immutable-HEAD barrier, ordering validation, and unique-key
            validation are untouched.

            Every contribution capability is provisional: the family currently
            returns the established multi-operation behavior modules while their
            interfaces are decomposed. No capability has two independent in-tree
            implementations, and `adjudicators` has no bundled plugin
            implementation at all.
          MD
        elsif family.name == :policy
          <<~MD
            ## Migration from legacy extension points

            The Policy family holds authorization-adjacent restrictions:
            `job_visibility_restriction` and `repository_filter`.

            Before:

            ```ruby
            provides job_visibility_restriction: "Acme::JobVisibility",
                     repository_filter: "Acme::RepositoryFilter"
            ```

            After:

            ```ruby
            policy job_visibility_restrictions: "Acme::JobVisibility",
                   repository_filters: "Acme::RepositoryFilter"
            ```

            Composition is explicit: every restriction applies. Policy is
            fail-closed, which differs from the usual decline-on-error rule. A
            provider that raises, times out, trips its circuit breaker, or returns
            an invalid value contributes `Syrus::Plugin::Policy::FAIL_CLOSED`
            instead of dropping out, and core callers then show a non-admin user no
            Jobs or repositories rather than an unrestricted list. An unavailable
            restriction can never widen visibility.

            Both capabilities are provisional: neither has two independent in-tree
            implementations.
          MD
        elsif family.name == :lifecycle
          <<~MD
            ## Migration from legacy extension points

            The Lifecycle family holds hooks that react to the plugin lifecycle and
            to domain events: `callbacks` and `domain_subscriber`. It is also the
            plugin-facing owner of reversible installation effects:
            `while_enabled` and `always` blocks register through
            `Syrus::Plugin::Lifecycle.define_effect`, which delegates to
            `Syrus::Installer.define`.

            Before:

            ```ruby
            provides callbacks: "Acme::Callbacks",
                     domain_subscriber: "Acme::Subscribers"
            ```

            After:

            ```ruby
            lifecycle callback_providers: "Acme::Callbacks",
                      domain_subscribers: "Acme::Subscribers"
            ```

            Composition is broadcast: every enabled, healthy plugin's hook runs and
            none claims or short-circuits the rest. Failure rule, unchanged by the
            migration:

            - A failing `on_boot` is logged and drains only that plugin's registered
              effects; the remaining plugins still boot. `on_shutdown` always drains.
              Enable and disable events run through `PluginLifecycleJob`, which
              drains on failure and re-raises so the job's retry machinery sees it.
              Lifecycle events are manifest-scoped, so `on_disable` still reaches a
              plugin that was just disabled.
            - Each domain subscriber runs inside its own `PluginInvocation`, so one
              subscriber raising never reaches the publisher or another subscriber.
              Async delivery enqueues one job per subscriber on that plugin's home
              queue.

            Both capabilities are provisional: they return the established
            behavior modules (`Syrus::Plugin::Callbacks`,
            `Syrus::Plugin::DomainSubscriber`) while their multi-operation
            interfaces are decomposed, and no capability has two independent
            in-tree implementations of one decomposed operation contract.
          MD
        elsif family.name == :data_policy
          <<~MD
            ## Migration from legacy extension points

            The DataPolicy family holds data-governance hooks: `retention_policy`,
            `purge_contributor`, and `preview_panel_retention`.

            Before:

            ```ruby
            provides retention_policy: "Acme::RetentionPolicy",
                     purge_contributor: "Acme::PurgeContributor"
            ```

            After:

            ```ruby
            data_policy retention_policies: "Acme::RetentionPolicy",
                        purge_contributors: "Acme::PurgeContributor"
            ```

            Composition is collect: every enabled contributor participates, and a
            retention run or purge must account for all of them. A contributor that
            cannot be resolved, raises, times out, trips its circuit breaker, or
            returns an invalid value contributes
            `Syrus::Plugin::DataPolicy::UNAVAILABLE` instead of dropping out
            silently, and callers report it while the remaining contributors still
            run:

            - Retention: `RetentionPolicyRegistry` logs an error for a failing
              provider and still returns every other provider's definitions.
            - Purge: a contributor that cannot report is listed in the purge report,
              and one that fails to remove its data adds a line to the purge result,
              while every other contributor still reports and removes.
            - Preview-panel retention is an any-of decision: a provider that
              declines does not retain the panel.

            All three capabilities are provisional: none has two independent
            in-tree implementations with a generated contract
            (`preview_panel_retentions` has one bundled implementation, and the
            purge and retention contributions keep their multi-operation module
            interfaces).
          MD
        elsif Syrus::Plugin::ServiceProvider::TIERS.key?(family.name)
          service_family_notes(family)
        end
        (<<~MD).sub(/\n+\z/, "\n")
          <!-- Generated by #{GENERATE_COMMAND}; do not edit. -->
          # `#{family.name}` plugin family

          Shape: `#{family.shape}`. Required core methods: #{family.required_core.map { |name| "`#{name}`" }.join(", ")}.

          Use `it_behaves_like "a valid #{family.name} provider"` from `syrus/plugin/test_kit`, passing literal plugin and provider strings plus call and decline contexts, to exercise this exact manifest declaration and keep coverage verifiable in isolated suite runs.

          ## Capabilities

          #{capabilities.rstrip}

          #{compatibility_notes&.rstrip}
        MD
      end

      SERVICE_FAMILY_EXAMPLES = {
        agent_runtime: [ %(agent_runtime agent_provider: "AgentProviders::Acme",\n              chat_provider: "ChatProviders::Acme"), "agent_provider: \"AgentProviders::Acme\", chat_provider: \"ChatProviders::Acme\"" ],
        execution_backend: [ %(execution_backend execution_backend: "Acme::Backend"), "execution_backend: \"Acme::Backend\"" ],
        runtime_session: [ %(runtime_session runtime_session_provider: "Acme::RuntimeSession"), "runtime_session_provider: \"Acme::RuntimeSession\"" ],
        source_host: [ %(source_host input_source: "InputSources::Acme",\n            repository_content_provider: "Acme::ContentProvider"), "input_source: \"InputSources::Acme\", repository_content_provider: \"Acme::ContentProvider\"" ],
        speech_to_text: [ %(speech_to_text speech_to_text_provider: "Acme::Transcriber"), "speech_to_text_provider: \"Acme::Transcriber\"" ]
      }.freeze
      SERVICE_FAMILY_REASONS = {
        agent_runtime: "Both capabilities are stable: each is implemented by several bundled agent plugins (Claude, Codex, Agy, Muse) and covered by generated contract examples.",
        execution_backend: "`execution_backend` is provisional: only the Container Execution plugin implements it in-tree.",
        runtime_session: "`runtime_session_provider` is stable: Runtime Terminal and Browser both implement it and are covered by generated contract examples.",
        source_host: "`input_source` (GitHub, Linear) and `repository_content_provider` (GitHub Host, Git Mirror) are stable. `source_control_provider` is provisional because only GitHub Source implements it, and `workspace_git_transport` is provisional because only Git Mirror implements it.",
        speech_to_text: "`speech_to_text_provider` is provisional: only the Whisper plugin implements it in-tree."
      }.freeze

      def service_family_notes(family)
        points = family.legacy_mappings.keys.map { |point| "`#{point}`" }.join(", ")
        after, legacy = SERVICE_FAMILY_EXAMPLES.fetch(family.name)
        <<~MD
          ## Migration from legacy extension points

          The #{family.name} service family absorbs the legacy extension points #{points}.

          A service keeps its own large stateful interface module (for example
          `Syrus::Plugin::AgentProvider`) as the contract. The family reuses only
          the declaration, dispatch, legacy-bridge and conformance machinery: the
          plugin declares one generated provider class per family, and each
          capability returns the plugin's service class (or classes). Selection
          (by provider key, repository, or request, and `Execution::Router` claim
          semantics) stays with the service and its core facade; core reads the
          list of services with `Syrus::Plugin::ServiceProvider.providers(capability)`.
          The required `available_for?(context)` reports whether the declaration
          is offering its services.

          Before:

          ```ruby
          provides #{legacy}
          ```

          After:

          ```ruby
          #{after}
          ```

          #{SERVICE_FAMILY_REASONS.fetch(family.name)}
        MD
      end

      private

      def host_entry(api)
        members = api.members.sort.map { |name| "- `#{name}`" }.join("\n")
        "### `#{api.name}`\n\nSince: `#{api.since}`\n\n#{api.summary}" + (members.empty? ? "" : "\n\nSupported members:\n\n#{members}")
      end

      def interface_path(interface)
        location = Object.const_source_location(interface.name)&.first
        Pathname.new(location).relative_path_from(Rails.root).to_s
      end

      def with_recorded_size(template)
        size = 0
        loop do
          rendered = template.sub("{{SIZE}}", size.to_s)
          return rendered if rendered.bytesize == size
          size = rendered.bytesize
        end
      end
    end
  end
end
