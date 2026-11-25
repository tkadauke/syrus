module RuntimeImages
  module Builds
    # The only authority a build has over the registry: publish into, and read
    # back from, the one namespace its request was made for, through the Runtime
    # Image Service. It exposes no other Service operation (no revoke, delete,
    # pull, or resolve), refuses a different namespace, and refuses to hand back
    # an image that is not that namespace's. The builder itself never receives
    # it, and registry credentials never leave the provider.
    class ScopedPublisher
      class OutOfScope < Error; end

      def initialize(service:, request:)
        @service = service
        @namespace = request.runtime_image_namespace
      end

      def publish(namespace: @namespace, **attrs)
        ensure_scope!(namespace)
        image = @service.publish(namespace: @namespace, **attrs)
        ensure_scope!(image.runtime_image_namespace)
        image
      end

      def inspect_image(image)
        ensure_scope!(image.runtime_image_namespace)
        @service.inspect_image(image)
      end

      private

      def ensure_scope!(namespace)
        return if namespace&.id == @namespace.id

        raise OutOfScope, "build for namespace #{@namespace.id} cannot publish to #{namespace&.id.inspect}"
      end
    end
  end
end
