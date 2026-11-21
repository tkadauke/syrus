# frozen_string_literal: true

require "set"
require "prism"

module Syrus
  module Plugin
    module FamilyContractKit
      module_function

      def validate!(declaration:, provider:, contexts:, decline_contexts:)
        family = declaration.family
        definition = Family.fetch(family)
        provider = provider.class unless provider.is_a?(Module)

        definition.required_core.each do |method_name|
          raise RSpec::Expectations::ExpectationNotMetError,
            "#{provider} must define required #{family} core method #{method_name}" unless provider.respond_to?(method_name)
          validate_signature!(provider, method_name, definition.core_method_contract(method_name))
        end

        declaration.capabilities.each do |capability_name|
          capability = definition.capabilities.fetch(capability_name)
          validate_signature!(provider, capability_name, capability.method_contract)
          context = fetch_context!(contexts, capability_name, capability.context, "call")
          result = invoke!(provider, capability_name, context)
          unless capability.return_contract.valid?(result)
            raise RSpec::Expectations::ExpectationNotMetError,
              "#{provider}.#{capability_name} must return #{capability.return_contract.description}; got #{result.inspect}"
          end

          decline_context = fetch_context!(decline_contexts, capability_name, capability.context, "decline")
          declined = invoke!(provider, capability_name, decline_context)
          next if declined == capability.absent

          raise RSpec::Expectations::ExpectationNotMetError,
            "#{provider}.#{capability_name} must decline with #{capability.absent.inspect}; got #{declined.inspect}"
        end
      end

      def fetch_context!(contexts, capability, expected, purpose)
        context = contexts.fetch(capability) do
          raise RSpec::Expectations::ExpectationNotMetError,
            "missing #{purpose} context for capability #{capability} (expected #{context_label(expected)})"
        end
        expected_class = resolve_context(expected)
        return context unless expected_class && !context.is_a?(expected_class)

        raise RSpec::Expectations::ExpectationNotMetError,
          "#{purpose} context for #{capability} must be a #{context_label(expected)}; got #{context.class}"
      end
      private_class_method :fetch_context!

      def invoke!(provider, capability, context)
        provider.public_send(capability, context)
      rescue ArgumentError => error
        raise RSpec::Expectations::ExpectationNotMetError,
          "#{provider}.#{capability} must be callable with the family context: #{error.message}"
      end
      private_class_method :invoke!

      def validate_signature!(provider, method_name, contract)
        parameters = provider.method(method_name).parameters
        expected = [ [ :req, nil ] ] * contract.required_positionals + [ [ :opt, nil ] ] * contract.optional_positionals +
          contract.required_keywords.map { |name| [ :keyreq, name ] } +
          contract.optional_keywords.map { |name| [ :key, name ] }
        actual = parameters.map { |kind, name| %i[keyreq key].include?(kind) ? [ kind, name ] : [ kind, nil ] }
        return if actual == expected

        raise RSpec::Expectations::ExpectationNotMetError,
          "#{provider}.#{method_name} must be callable with #{contract.required_positionals} required and " \
          "#{contract.optional_positionals} optional positional argument(s); got #{parameters.inspect}"
      rescue NameError
        raise RSpec::Expectations::ExpectationNotMetError, "#{provider} must define capability #{method_name}"
      end
      private_class_method :validate_signature!

      def resolve_context(context)
        return context if context.is_a?(Module)
        context.to_s.safe_constantize
      end
      private_class_method :resolve_context

      def context_label(context) = context.respond_to?(:name) ? context.name : context.to_s
      private_class_method :context_label
    end

    module FamilyContractCoverage
      Entry = Data.define(:plugin, :family, :provider)

      module_function

      def declaration!(plugin:, family:, provider:, manifests: PluginRegistry.all_plugins)
        manifest = manifests.find { |candidate| candidate.name == plugin.to_s }
        raise ArgumentError, "Unknown plugin #{plugin.inspect}" unless manifest

        declaration = Array(manifest.family_provides).find do |candidate|
          candidate.family == family.to_sym && candidate.provider == provider.to_s
        end
        raise ArgumentError,
          "#{plugin} does not declare #{provider} as a #{family} provider" unless declaration

        declaration
      end

      def missing(manifests: PluginRegistry.all_plugins)
        manifests.reject(&:external).flat_map do |manifest|
          covered = covered_entries(manifest)
          Array(manifest.family_provides).filter_map do |declaration|
            entry = Entry.new(plugin: manifest.name, family: declaration.family, provider: declaration.provider)
            entry unless covered.include?(entry)
          end
        end
      end

      def covered_entries(manifest)
        return Set.new unless manifest.plugin_root

        Pathname.new(manifest.plugin_root).glob("spec/**/*_spec.rb").each_with_object(Set.new) do |path, entries|
          result = Prism.parse_file(path)
          raise "Could not parse #{path}: #{result.errors.map(&:message).join(', ')}" unless result.success?

          collect_contract_entries(result.value, entries, manifest.name)
        end
      end
      private_class_method :covered_entries

      def collect_contract_entries(node, entries, plugin)
        if node.is_a?(Prism::CallNode) && node.name == :it_behaves_like
          entry = entry_for_call(node, plugin)
          entries << entry if entry
        end
        node.compact_child_nodes.each { |child| collect_contract_entries(child, entries, plugin) }
      end
      private_class_method :collect_contract_entries

      def entry_for_call(node, plugin)
        arguments = node.arguments&.arguments || []
        example_name = static_string(arguments.first)
        match = example_name&.match(/\Aa valid ([a-z0-9_]+) provider\z/)
        return unless match

        keyword_elements = arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode)
        keywords = keyword_elements.to_h do |element|
          [ static_symbol(element.key), static_string(element.value) ]
        end
        return unless keywords[:plugin] == plugin && keywords[:provider]

        Entry.new(plugin:, family: match[1].to_sym, provider: keywords[:provider])
      end
      private_class_method :entry_for_call

      def static_string(node)
        node.unescaped if node.is_a?(Prism::StringNode)
      end
      private_class_method :static_string

      def static_symbol(node)
        node.unescaped.to_sym if node.is_a?(Prism::SymbolNode)
      end
      private_class_method :static_symbol
    end
  end
end
