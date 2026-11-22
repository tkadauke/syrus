# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "set"
require "securerandom"
require "tmpdir"
require "syrus/plugin_loader"
require "syrus/plugin/family_contract_kit"
require "syrus/plugin/external_reviewer_contract_kit"

module Syrus
  module Plugin
    # RSpec support for exercising an installed plugin against a real Syrus
    # host. The kit deliberately accepts absolute plugin paths and does not
    # rely on the Syrus source checkout being present.
    module TestKit
      class PluginUnderTest
        attr_reader :root, :name

        def initialize(root, name: nil)
          @root = Pathname.new(root).expand_path
          @name = name || specification.name
        end

        def specification
          @specification ||= begin
            gemspecs = root.glob("*.gemspec")
            raise ArgumentError, "expected exactly one gemspec in #{root}, found #{gemspecs.length}" unless gemspecs.one?

            Gem::Specification.load(gemspecs.first.to_s) || raise(ArgumentError, "invalid gemspec #{gemspecs.first}")
          end
        end

        def manifest
          Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == name }
        end

        def health
          Syrus::PluginRegistry.health.status(name)
        end

        def frontend
          PluginFrontendAssets.entries.find { |entry| entry[:name] == name }
        end
      end

      module Helpers
        def syrus_plugin(root, name: nil) = PluginUnderTest.new(root, name:)

        # A definition lives on a module extended with Syrus::PluginApi, never
        # on a singleton class. Every other module in ObjectSpace is probed
        # too, and any of them may answer respond_to? by raising, so a probe
        # that raises means "not a plugin namespace" rather than a crash that
        # depends on which classes earlier examples left loaded.
        def plugin_definition_of(namespace)
          return if namespace.singleton_class?

          namespace.syrus_plugin_definition if namespace.respond_to?(:syrus_plugin_definition)
        rescue StandardError
          nil
        end

        def with_syrus_plugin(root, name: nil)
          plugin = syrus_plugin(root, name:)
          snapshot = Syrus::PluginRegistry.snapshot
          boot_snapshot = Syrus::PluginRegistry.boot_snapshot
          load_path = $LOAD_PATH.dup
          application_root = Dir.mktmpdir("syrus-plugin-test-host")
          roots = Syrus::PluginRoots.new(application_root:, external_path: plugin.root.dirname)
          Syrus::PluginRegistry.reset!
          Syrus::PluginLoader.load!(plugin_roots: roots)
          definition = ObjectSpace.each_object(Module).filter_map do |namespace|
            plugin_definition_of(namespace)
          end.find { |candidate| candidate&.name == plugin.name }
          Syrus::PluginLoader.install_definition!(definition) if definition
          yield plugin
        ensure
          Syrus::PluginRegistry.restore(snapshot) if snapshot
          Syrus::PluginRegistry.boot_snapshot = boot_snapshot
          $LOAD_PATH.replace(load_path) if load_path
          FileUtils.remove_entry(application_root) if application_root && File.exist?(application_root)
        end

        # Stable, deliberately small builders keep repository-only factories
        # out of the public test-kit contract and packaged host images.
        def build_plugin_user(**attributes)
          User.create!({
            email_address: "plugin-test-#{SecureRandom.hex(4)}@example.com",
            password: "supersecret"
          }.merge(attributes))
        end

        def build_plugin_repository(**attributes)
          user = attributes.delete(:user) || build_plugin_user
          Repository.create!({
            user:,
            owner: "plugin-test",
            name: "repository-#{SecureRandom.hex(6)}"
          }.merge(attributes))
        end

        def build_plugin_job(**attributes)
          repository = attributes.delete(:repository) || build_plugin_repository(user: attributes[:user] || build_plugin_user)
          user = attributes.delete(:user) || repository.user
          Job.create!({ user:, owner_user: user, repository:, issue_number: 42 }.merge(attributes))
        end
      end

      module Matchers
        extend RSpec::Matchers::DSL

        matcher :be_plugin_loaded do
          match do |plugin|
            plugin.manifest&.loaded && plugin.manifest.plugin_root.present? &&
              Pathname.new(plugin.manifest.plugin_root).realpath == plugin.root.realpath
          rescue Errno::ENOENT
            false
          end
          failure_message { |plugin| "expected #{plugin.name} to be loaded from #{plugin.root}, but manifest was #{plugin.manifest.inspect}" }
        end

        matcher :be_plugin_healthy do
          match { |plugin| plugin.health&.healthy? }
          failure_message { |plugin| "expected #{plugin.name} to be healthy, but health was #{plugin.health&.state}: #{Array(plugin.health&.reasons).join('; ')}" }
        end

        matcher :register_plugin_provider do |extension_point|
          chain(:matching) { |provider| @provider = provider }
          match do |plugin|
            @providers = Syrus::PluginRegistry.providers_for(extension_point)
            plugin.manifest && (@provider ? @providers.include?(@provider) : Array(plugin.manifest.provides[extension_point.to_sym]).any?)
          end
          failure_message { |plugin| "expected #{plugin.name} to register a provider for #{extension_point}; registered providers: #{@providers.inspect}" }
        end

        matcher :have_plugin_route do |path|
          chain(:using) { |session| @session = session }
          chain(:with_status) { |status| @status = status }
          match do |_plugin|
            unless @session
              @configuration_error = "requires .using(an integration session)"
              next false
            end
            @session.get(path)
            @actual_status = @session.response.status
            @actual_status == (@status || 200)
          end
          failure_message { "expected GET #{path} to respond with #{@status || 200}#{@configuration_error ? ", but #{@configuration_error}" : ", got #{@actual_status}"}" }
        end

        matcher :have_applicable_plugin_migrations do
          match do |plugin|
            path = plugin.root.join("db/migrate")
            @error = nil
            context = ActiveRecord::MigrationContext.new([ path.to_s ])
            context.migrations.each { |migration| context.schema_migration.delete_version(migration.version.to_s) }
            context.up
            @paths = ActiveRecord::Migrator.migrations_paths
            @paths.include?(path.to_s)
          rescue StandardError => e
            @error = e
            false
          end
          failure_message { |plugin| "expected #{plugin.name} migrations to apply#{@error ? ", but #{@error.class}: #{@error.message}" : ", but #{plugin.root.join('db/migrate')} was not registered"}" }
        end

        matcher :have_plugin_frontend do
          match do |plugin|
            @entry = plugin.frontend
            bundle = plugin.manifest && PluginFrontendAssets.find(plugin.name, :bundle)
            @actual_hash = bundle && Digest::SHA256.hexdigest([ bundle, PluginFrontendAssets.find(plugin.name, :css) ].compact.map { |asset| File.binread(asset.path) }.join)
            @entry && bundle && @entry[:hash] == @actual_hash
          end
          failure_message { |plugin| "expected #{plugin.name} to have a frontend bundle whose hash matches bootstrap; entry=#{@entry.inspect}, computed_hash=#{@actual_hash.inspect}" }
        end

        matcher :have_plugin_cli_command do |*path|
          chain(:executable_with) { |user| @user = user }
          match do |plugin|
            command_path = path.flatten.map(&:to_s)
            @command = PluginCliCommands.catalog.find do |candidate|
              candidate.plugin == plugin.name && candidate.path == command_path
            end
            handler = @command.handler.constantize.new if @command && @user
            @result = handler.call(args: {}, flags: {}, user: @user) if handler
            @command && (!@user || @result.present?)
          rescue StandardError => e
            @error = e
            false
          end
          failure_message { |plugin| "expected #{plugin.name} CLI command #{path.flatten.join(' ')} to be present#{@user ? ' and executable' : ''}#{@error ? ", but #{@error.class}: #{@error.message}" : ''}" }
        end

        matcher :have_matching_plugin_locales do
          match do |plugin|
            entries = plugin.frontend&.fetch(:locales, []) || []
            @missing = []
            grouped = entries.group_by { |entry| entry[:namespace] }
            grouped.any? && grouped.all? do |namespace, locales|
              by_locale = locales.index_by { |entry| entry[:locale] }
              absent = %w[en de la] - by_locale.keys
              @missing.concat(absent.map { |locale| "#{locale}/#{namespace}" })
              next false if absent.any?

              keys = by_locale.transform_values { |entry| flatten_json_keys(JSON.parse(File.read(PluginFrontendAssets.find_locale(plugin.name, entry[:locale], namespace).path))) }
              mismatch = keys.values.uniq.length > 1
              @missing << "mismatched keys for #{namespace}: #{keys.inspect}" if mismatch
              !mismatch
            end
          end
          failure_message { |plugin| "expected #{plugin.name} locale files in en, de, and la with matching keys; #{@missing.join(', ')}" }
        end

        matcher :have_valid_plugin_manifest do
          match do |plugin|
            @errors = plugin.manifest&.validation_errors || []
            plugin.specification && plugin.manifest && @errors.empty?
          rescue StandardError => e
            @errors = [ "#{e.class}: #{e.message}" ]
            false
          end
          failure_message { |plugin| "expected #{plugin.name} manifest to be valid; #{@errors.join('; ')}" }
        end

        matcher :satisfy_requires_syrus do
          match do |plugin|
            @requirement = Gem::Requirement.new(plugin.specification.metadata["requires_syrus"].to_s)
            @release = SyrusVersion.release
            @release.nil? || @requirement.satisfied_by?(@release)
          rescue StandardError => e
            @error = e
            false
          end
          failure_message { |plugin| "expected #{plugin.name} requires_syrus #{@requirement} to accept running Syrus #{@release}#{@error ? "; #{@error.message}" : ''}" }
        end

        matcher :have_clean_plugin_host_surface do
          match do |plugin|
            @result = Syrus::PluginHostSurface::Scanner.new(plugin.root).call
            @result.error.nil? && @result.legacy.empty? && @result.unlisted.empty?
          end
          failure_message { |plugin| "expected #{plugin.name} host-surface scan to be clean; error=#{@result&.error.inspect}, legacy=#{@result&.legacy.inspect}, unsupported=#{@result&.unlisted.inspect}" }
        end

        def flatten_json_keys(value, prefix = nil)
          return [ prefix ] unless value.is_a?(Hash)
          value.flat_map { |key, child| flatten_json_keys(child, [ prefix, key ].compact.join(".")) }.sort
        end
      end

      module SharedExamples
        def self.install!
          unless @base_installed
            RSpec.shared_examples "a valid Syrus plugin provider" do |extension_point|
              it "implements the extension-point contract" do
                interface = Syrus::PluginRegistry::INTERFACE_FOR.fetch(extension_point.to_sym).call
                provider_class = subject.is_a?(Class) ? subject : subject.class
                expect(provider_class.ancestors).to include(interface)
              end
            end
            @base_installed = true
          end

          unless @external_reviewer_installed
            RSpec.shared_examples "a valid external reviewer" do |context:, refresh_context:, timeout: nil|
              it "satisfies the external-reviewer service contract" do
                resolved_context = context.respond_to?(:call) ? instance_exec(&context) : context
                resolved_refresh = refresh_context.respond_to?(:call) ? instance_exec(&refresh_context) : refresh_context
                Syrus::Plugin::ExternalReviewerContractKit.validate!(
                  provider: subject, context: resolved_context, refresh_context: resolved_refresh, timeout:
                )
              end
            end
            @external_reviewer_installed = true
          end

          Syrus::Plugin::Family.all.each do |family|
            @installed_families ||= Set.new
            next unless @installed_families.add?(family.name)
            RSpec.shared_examples "a valid #{family.name} provider" do |plugin:, provider:, contexts:, decline_contexts:|
              declaration = Syrus::Plugin::FamilyContractCoverage.declaration!(
                plugin:, family: family.name, provider:
              )
              it "satisfies the generated #{family.name} family contract" do
                provider_class = subject.is_a?(Module) ? subject : subject.class
                expect(provider_class.name).to eq(declaration.provider),
                  "expected the shared example subject to be #{declaration.provider}, got #{provider_class.name || provider_class.inspect}"
                resolved_contexts = contexts.respond_to?(:call) ? instance_exec(&contexts) : contexts
                resolved_declines = decline_contexts.respond_to?(:call) ? instance_exec(&decline_contexts) : decline_contexts
                Syrus::Plugin::FamilyContractKit.validate!(declaration:, provider: subject,
                  contexts: resolved_contexts, decline_contexts: resolved_declines)
              end
            end
          end
        end
      end

      def self.included(base)
        base.include Helpers
        base.include Matchers
      end
    end
  end
end

RSpec.configure do |config|
  config.include Syrus::Plugin::TestKit::Helpers
  config.include Syrus::Plugin::TestKit::Matchers
end
Syrus::Plugin::TestKit::SharedExamples.install!
