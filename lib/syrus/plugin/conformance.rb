# frozen_string_literal: true

module Syrus
  module Plugin
    class Conformance
      Finding = Data.define(:plugin, :family, :provider, :code, :message)

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
          check_method(plugin, declaration, provider, method_name, expected_arguments(method_name))
        end
        errors.concat(Array(declaration.capabilities).filter_map do |capability|
          unless definition.capabilities.key?(capability)
            next finding(plugin, declaration, :unknown_capability,
              "#{declaration.provider} claims unknown #{declaration.family} capability #{capability}")
          end
          check_method(plugin, declaration, provider, capability, expected_arguments(capability))
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

      def expected_arguments(method_name) = %i[key display_name].include?(method_name) ? 0 : 1

      def acceptable_signature?(parameters, expected)
        positional = parameters.count { |kind, _| %i[req opt].include?(kind) }
        required = parameters.count { |kind, _| kind == :req }
        keywords = parameters.any? { |kind, _| %i[keyreq key keyrest].include?(kind) }
        rest = parameters.any? { |kind, _| kind == :rest }
        !keywords && !rest && positional == expected && required == expected
      end

      def signature_label(expected) = expected.zero? ? "no arguments" : "one required context argument and no keywords"

      def finding(plugin, declaration, code, message)
        Finding.new(plugin: plugin.to_s, family: declaration.family.to_sym,
          provider: declaration.provider.to_s, code:, message:)
      end
    end
  end
end
