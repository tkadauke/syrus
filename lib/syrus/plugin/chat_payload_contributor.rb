module Syrus
  module Plugin
    # Marker interface for a plugin that adds its own data to the chat payload.
    #
    # The chat payload is one big JSON document the chat page reads, and three
    # of its top-level keys belonged to plugins rather than to core:
    # `whiteboard` (whiteboard), `preview_panels` (preview_tools), and
    # `video_walkthroughs`. Core built all of them inline, which meant it had
    # to know those models and their serialization.
    #
    # Providers expose:
    #
    #   .chat_payload(chat_session:, context:) => { key => value }
    #   .chat_payload_paths(chat_session:)    => { key => "/api/..." }   (optional)
    #   .chat_payload_counts(chat_session:)   => { key => Integer }      (optional)
    #
    # `context` carries what the host resolved for this request: `:params`, so
    # a contributor can honour a query flag it owns (whiteboard only
    # serializes the full scene when `include_whiteboard` is present, because
    # the scene is large), and `:ssl`, which preview_tools needs to build panel
    # URLs. It is a hash so new host-side context does not change every
    # provider's signature.
    #
    # Counts are returned rather than merged into core's single counts query:
    # one indexed COUNT per contributor is cheaper than letting plugins
    # template SQL into a core statement.
    #
    # A contributor must not overwrite a key core already set; the host raises
    # rather than let one silently win.
    module ChatPayloadContributor
      def self.included(base) = base.extend(self)

      def chat_payload_paths(chat_session:) = {}
      def chat_payload_counts(chat_session:) = {}
    end
  end
end
