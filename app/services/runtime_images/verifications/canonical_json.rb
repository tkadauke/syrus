module RuntimeImages
  module Verifications
    module CanonicalJson
      module_function
      def value(object)
        case object
        when Hash then object.stringify_keys.sort.to_h { |key, item| [ key, value(item) ] }
        when Array then object.map { |item| value(item) }
        else object
        end
      end
      def digest(object) = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(value(object)))}"
    end
  end
end
