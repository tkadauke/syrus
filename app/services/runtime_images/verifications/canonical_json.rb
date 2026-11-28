module RuntimeImages
  module Verifications
    module CanonicalJson
      module_function

      def value(object)
        case object
        when Hash
          object.stringify_keys.sort.to_h { |key, item| [ key, value(item) ] }
        when Array
          object.map { |item| value(item) }
        else
          object
        end
      end

      def generate(object) = JSON.generate(value(object))
      def digest(object) = "sha256:#{Digest::SHA256.hexdigest(generate(object))}"
    end
  end
end
