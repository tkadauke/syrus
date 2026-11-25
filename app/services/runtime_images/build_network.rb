module RuntimeImages
  # Administrator-controlled egress for runtime image builds. A build has no
  # network of its own: it runs in an empty network namespace whose only route
  # is a loopback relay to an enforcing proxy on the worker. Every destination
  # is decided here, against rules an administrator declared by source class.
  module BuildNetwork
    class Error < StandardError; end
    class InvalidHost < Error; end
  end
end
