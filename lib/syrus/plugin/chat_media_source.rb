module Syrus
  module Plugin
    # Marker interface for a kind of media a chat can attach to a Job proposal
    # or to feedback on an existing Job.
    #
    # Media refs are `"<kind>:<id>"` strings the agent passes around, and the
    # same three questions get asked about them in five places: is this ref
    # valid, does it belong to this chat, and how does it become a Job
    # attachment. Those used to be a `case kind` in each of ChatMediaAttacher,
    # ChatProposal, submit_chat_feedback, list_chat_media, and ChatMediaRef's
    # own format regex -- with `snapshot` (whiteboard_tools) and
    # `preview_panel_version` (preview_tools) hardcoded into core.
    #
    # Providers expose:
    #
    #   .chat_media_kind                                   => "snapshot"
    #   .chat_media_exists?(chat_session:, id:)            => true / false
    #   .attach_chat_media(chat_session:, job:, ref:, id:) => Document, [Document, ...], or nil
    #   .list_chat_media(chat_session:)                    => [ { ... }, ... ]  (optional)
    #   .chat_media_context(chat_session:)                 => { key => value }  (optional)
    #
    # `list_chat_media` returns already-shaped entries for the list_chat_media
    # tool, each carrying at least `id` ("<kind>:<id>") and `kind`.
    # `chat_media_context` adds kind-specific context beside the entries --
    # whiteboard_tools reports how many elements are currently on the canvas.
    #
    # `attach_chat_media` returns nil when the id does not resolve; the caller
    # reports that as a skipped ref rather than failing the whole attach.
    module ChatMediaSource
      # Sources are modules answering at the module level, so the optional
      # defaults have to be extended in as well as included -- the same shape
      # Syrus::Plugin::Callbacks uses.
      def self.included(base) = base.extend(self)

      def list_chat_media(chat_session:) = []
      def chat_media_context(chat_session:) = {}
    end
  end
end
