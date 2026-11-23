# frozen_string_literal: true

module Syrus
  module Plugin
    module Declarations
      # Adapts manifest declarations into the provider objects each legacy
      # extension point has always handed to core. This is the legacy bridge for
      # declarations: core keeps asking `providers_for(:slug_type)` and friends,
      # and the registry answers with a plugin's registered provider classes
      # *and* these adapters, in plugin priority order. Core never merges the two
      # forms itself.
      #
      # An adapter answers from the declared data. Anything that is behavior (a
      # record lookup, a config parser, a probe command) is a constant *name* in
      # the declaration and is resolved at the call that needs it, so building
      # the adapter, listing the manifest and reading a slug prefix never load
      # plugin code. Adapters are memoized by declaration content; they hold only
      # strings, so a code reload cannot leave one stale.
      module Providers
        CACHE = {}
        MUTEX = Mutex.new

        module_function

        def for(plugin, point, entries)
          entries.map do |entry|
            MUTEX.synchronize { CACHE[[ plugin, point, entry ]] ||= build(plugin, point, entry) }
          end
        end

        def build(plugin, point, entry)
          const_get(point.to_s.camelize, false).new(plugin, entry)
        end

        def resolve(name)
          return nil if name.nil?

          name.constantize
        end

        # Shared by every adapter: who declared it, and a readable identity for
        # logs (`PluginInvocation` and `KindRegistry` interpolate the provider).
        class Base
          attr_reader :declaring_plugin, :entry

          def initialize(plugin, entry)
            @declaring_plugin = plugin
            @entry = entry
          end

          def declaration? = true
          def name = "#{declaring_plugin} #{self.class.name.demodulize.underscore} declaration"
          def to_s = name
          def inspect = "#<#{name}>"

          # Behavior classes named by the declaration, for `plugin_name_for`.
          def owns_implementation?(candidate)
            Array(implementation_names).any? { |constant| candidate.respond_to?(:name) && candidate.name == constant }
          end

          def implementation_names = []

          private

          def restore_symbols(attrs, list)
            attrs = attrs.deep_dup
            Declarations::SYMBOL_FIELDS.fetch(list, []).each do |field|
              attrs[field] = attrs[field].to_sym if attrs[field].is_a?(String)
            end
            attrs
          end
        end

        class WorkflowKinds < Base
          def trigger_kinds = entry[:trigger_kinds].map { |attrs| restore_symbols(attrs, :trigger_kinds) }
          def step_kinds = entry[:step_kinds].map { |attrs| restore_symbols(attrs, :step_kinds) }
          def job_kinds = entry[:job_kinds].map(&:deep_dup)
          def work_definitions = entry[:work_definitions].map { |constant| Providers.resolve(constant) }
          def implementation_names = entry[:work_definitions]
        end

        class JobOrigin < Base
          def origin_key = entry[:key]
          def icon = entry[:icon]
          def label(origin_id:, repository: nil) = delegate(:label, origin_id.to_s, origin_id:, repository:)
          def url(origin_id:, repository: nil) = delegate(:url, nil, origin_id:, repository:)
          def synthetic_issue(origin_id:, repository: nil) = delegate(:synthetic_issue, nil, origin_id:, repository:)
          def auto_approve_mode(origin_id:, repository: nil) = delegate(:auto_approve_mode, nil, origin_id:, repository:)
          def implementation_names = [ entry[:provider] ].compact

          private

          # The behavior class is optional and loaded only here. A disabled or
          # unloadable provider degrades to the default, the same way an absent
          # origin does.
          def delegate(method_name, default, **arguments)
            behavior = Providers.resolve(entry[:provider])
            return default unless behavior.respond_to?(method_name)

            behavior.public_send(method_name, **arguments)
          end
        end

        class SlugType < Base
          # A real class, because core and the generated client metadata treat a
          # slug type as `Syrus::Plugin::SlugType` (class-level methods).
          def self.build_class(plugin, entry)
            Class.new do
              include Syrus::Plugin::SlugType

              define_singleton_method(:name) { "#{plugin} slug_type #{entry[:prefix]} declaration" }
              define_singleton_method(:to_s) { name }
              define_singleton_method(:declaring_plugin) { plugin }
              define_singleton_method(:entry) { entry }
              define_singleton_method(:declaration?) { true }
              define_singleton_method(:prefix) { entry[:prefix] }
              define_singleton_method(:display_label) { entry[:display_label] }
              define_singleton_method(:copyable?) { entry[:copyable] }
              define_singleton_method(:linkable?) { entry[:linkable] }
              define_singleton_method(:preview_available?) { entry[:preview_available] }
              define_singleton_method(:linkifies_generated_text?) { entry[:linkifies_generated_text] }
              define_singleton_method(:behavior) { Providers.resolve(entry[:resolver]) }
              define_singleton_method(:implementation_names) { [ entry[:resolver] ] }
              define_singleton_method(:owns_implementation?) do |candidate|
                candidate.respond_to?(:name) && candidate.name == entry[:resolver]
              end

              define_singleton_method(:client_path) do |id|
                template = entry[:client_path]
                next "/s/#{canonical_slug(id)}" unless template

                template.gsub(":slug", canonical_slug(id)).gsub(":id", id.to_s)
              end

              define_singleton_method(:record_for) { |id, user:| behavior.record_for(id, user:) }
              define_singleton_method(:web_path) { |record| behavior.web_path(record) }
              define_singleton_method(:api_preview_path) do |record|
                behavior.respond_to?(:api_preview_path) ? behavior.api_preview_path(record) : nil
              end
            end
          end

          def self.new(plugin, entry) = build_class(plugin, entry)
        end

        class ProblemProvider < Base
          def problem_namespace = entry[:namespace]
          def problem_kinds = entry[:kinds].map { |attrs| restore_symbols(attrs, :problem_kinds) }
        end

        class RepositoryConfiguration < Base
          def key = entry[:key]
          def schema_version = entry[:schema_version]
          def legacy_keys = entry[:legacy_keys]
          def implementation_names = [ entry[:provider] ]

          def parse(value:, version:, scope:)
            raise ArgumentError, "unsupported schema version #{version}" unless version == schema_version

            behavior.parse(value:, version:, scope:)
          end

          def serialize(value:) = behavior.serialize(value:)
          def overlay(root:, project:) = behavior.respond_to?(:overlay) ? behavior.overlay(root:, project:) : (project.nil? ? root : project)

          def affected_project?(configuration:, project:, changed_files:)
            return true unless behavior.respond_to?(:affected_project?)

            behavior.affected_project?(configuration:, project:, changed_files:)
          end

          private

          def behavior = Providers.resolve(entry[:provider])
        end

        class StepEnvironment < Base
          def initialize(plugin, entry)
            super
            return unless entry[:extra_env]

            # Optional on the contract: only a declaration that names a computing
            # class answers `respond_to?(:extra_env)`, which is what
            # Steps::Prepare checks before calling it.
            define_singleton_method(:extra_env) do |scope:, workspace_path:|
              Providers.resolve(entry[:extra_env]).extra_env(scope:, workspace_path:)
            end
          end

          def forwarded_env_keys = entry[:forwarded_env_keys]
          def implementation_names = [ entry[:extra_env] ].compact
        end

        class WorkerCapabilityProbe < Base
          def declared_token = entry[:token]
          def declared_dimension = entry[:dimension]
          def implementation_names = [ entry[:probe] ]

          # The probe class builds the command; the declaration owns what the
          # probe is allowed to claim. A probe that reports anything else is
          # dropped, so the capability tokens a manifest advertises are the only
          # ones the worker can ever record.
          def capability_probes(env: ENV)
            Array(Providers.resolve(entry[:probe]).capability_probes(env:)).select do |probe|
              attrs = probe.respond_to?(:to_h) ? probe.to_h.transform_keys(&:to_sym) : {}
              attrs[:dimension].to_s == entry[:dimension] && attrs[:token].to_s == entry[:token]
            end
          end
        end
      end
    end
  end
end
