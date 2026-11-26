module RuntimeImages
  module Verifications
    class ManifestVerifier
      def initialize(service: Service.new)
        @service = service
      end

      def call(image:, **)
        inspection = @service.inspect_image(image)
        return Result.fail(failure_class: :infrastructure, code: :registry_unavailable, message: "registry could not confirm the immutable digest") unless inspection.present

        Result.pass(evidence_references: [ { "kind" => "registry_manifest", "digest" => image.digest } ])
      rescue ProviderError, Timeout::Error, SystemCallError => e
        Result.fail(failure_class: :infrastructure, code: :scanner_unavailable, message: "registry inspection unavailable: #{e.class}")
      end
    end
  end
end
