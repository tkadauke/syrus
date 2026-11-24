module Syrus
  module Host
    # Plugin-facing entry to the Runtime Image Service for images a plugin
    # builds and needs every worker to be able to run.
    module RuntimeImages
      def self.available? = ::RuntimeImages::BuiltImages.new.available?

      def self.find(**) = ::RuntimeImages::BuiltImages.new.find(**)

      def self.publish_local(**) = ::RuntimeImages::BuiltImages.new.publish_local(**)

      def self.acquire(image, &) = ::RuntimeImages::BuiltImages.new.acquire(image, &)
    end
  end
end
