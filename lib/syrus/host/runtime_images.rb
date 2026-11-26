module Syrus
  module Host
    # Plugin-facing entry to the Runtime Image Service for images a plugin
    # builds and needs every worker to be able to run.
    module RuntimeImages
      def self.available? = ::RuntimeImages::BuiltImages.new.available?

      def self.find(**) = ::RuntimeImages::BuiltImages.new.find(**)

      def self.publish_local(**) = ::RuntimeImages::BuiltImages.new.publish_local(**)

      def self.acquire(image, &) = ::RuntimeImages::BuiltImages.new.acquire(image, &)

      def self.active_base(**) = ::RuntimeImages::BuildRequests.new.active_base(**)

      def self.request_build(**) = ::RuntimeImages::BuildRequests.new.submit(**)

      def self.retain(image, **) = ::RuntimeImages::Service.new.retain(image, **)

      def self.revoke(image, **) = ::RuntimeImages::Service.new.revoke(image, **)

      def self.delete(image, **) = ::RuntimeImages::Service.new.delete(image, **)

      def self.audit(event_type, **) = ::RuntimeImages::Audit.record(event_type, **)
    end
  end
end
