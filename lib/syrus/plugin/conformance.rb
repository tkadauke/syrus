# frozen_string_literal: true

module Syrus
  module Plugin
    class Conformance
      Finding = PluginHealth::Finding

      def initialize(manifests) = @manifests = manifests

      def findings
        @findings ||= @manifests.flat_map { |manifest| findings_for(manifest) }.freeze
      end

      def conforming?(plugin:, family:)
        findings.none? { |finding| finding.plugin == plugin.to_s && finding.family == family.to_sym }
      end

      private

      def findings_for(manifest)
        Array(manifest.family_provides).flat_map do |declaration|
          check_declaration(manifest.name, declaration)
        rescue StandardError, ScriptError => error
          [ finding(manifest.name, declaration, :load_error,
            "could not load #{declaration.provider}: #{error.class}: #{error.message}") ]
        end
      end

      def check_declaration(plugin, declaration)
        definition = Family.fetch(declaration.family)
        provider = Object.const_get(declaration.provider)
        errors = definition.required_core.filter_map do |method_name|
          check_method(plugin, declaration, provider, method_name, definition.core_method_contract(method_name))
        end
        errors.concat(Array(declaration.capabilities).filter_map do |capability|
          unless definition.capabilities.key?(capability)
            next finding(plugin, declaration, :unknown_capability,
              "#{declaration.provider} claims unknown #{declaration.family} capability #{capability}")
          end
          check_method(plugin, declaration, provider, capability, definition.method_contract(capability))
        end)
        errors
      rescue ArgumentError => error
        [ finding(plugin, declaration, :unknown_family, error.message) ]
      end

      def check_method(plugin, declaration, provider, method_name, expected)
        method = provider.method(method_name)
        return if acceptable_signature?(method.parameters, expected)

        finding(plugin, declaration, :wrong_signature,
          "#{declaration.provider}.#{method_name} must accept #{signature_label(expected)}; got #{method.parameters.inspect}")
      rescue NameError
        code = declaration.capabilities.include?(method_name) ? :missing_capability : :missing_required_core
        finding(plugin, declaration, code, "#{declaration.provider} does not define required method #{method_name}")
      end

      def acceptable_signature?(parameters, contract)
        positional = parameters.count { |kind, _| %i[req opt].include?(kind) }
        required = parameters.count { |kind, _| kind == :req }
        required_keywords = parameters.filter_map { |kind, name| name if kind == :keyreq }
        optional_keywords = parameters.filter_map { |kind, name| name if kind == :key }
        variadic = parameters.any? { |kind, _| %i[rest keyrest block].include?(kind) }
        optional = parameters.count { |kind, _| kind == :opt }
        !variadic && positional == contract.required_positionals + contract.optional_positionals &&
          required == contract.required_positionals && optional == contract.optional_positionals &&
          required_keywords.map(&:to_sym).sort == contract.required_keywords &&
          optional_keywords.map(&:to_sym).sort == contract.optional_keywords
      end

      def signature_label(contract)
        return "no arguments" if contract.required_positionals.zero? && contract.optional_positionals.zero? &&
          contract.required_keywords.empty? && contract.optional_keywords.empty?

        "#{contract.required_positionals} required and #{contract.optional_positionals} optional positional argument(s), " \
          "required keywords #{contract.required_keywords.inspect}, and optional keywords #{contract.optional_keywords.inspect}"
      end

      def finding(plugin, declaration, code, message)
        Finding.conformance(
          plugin:, family: declaration.family, provider: declaration.provider, code:, message:
        )
      end
    end
  end
end
