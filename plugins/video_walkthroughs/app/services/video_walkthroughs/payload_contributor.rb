module VideoWalkthroughs
  # The chat payload's `video_walkthroughs` list, its upload path, and the
  # per-user "is Gemini configured" flag core used to build inline.
  #
  # `walkthroughs_enabled` is gone: it was a Labs flag the composer read to
  # decide whether to offer video intake, and the plugin's enabled state is
  # that answer now. The composer reads the presence of the upload path
  # instead, so an installed-but-disabled plugin contributes nothing and the
  # intake disappears without core knowing why.
  module PayloadContributor
    include Syrus::Plugin::ChatPayloadContributor

    def self.chat_payload(chat_session:, context:)
      {
        video_walkthroughs: walkthroughs_json(chat_session),
        # Whether the *viewer* can actually analyze a video they upload. The
        # composer uses it to offer the setup sheet rather than let someone
        # record five minutes and then fail.
        gemini_configured: Current.user&.gemini_configured? || false
      }
    end

    # Both paths are contributed rather than built in the frontend, so core
    # never hardcodes a plugin's URL -- which the boundary audit enforces.
    def self.chat_payload_paths(chat_session:)
      {
        app_video_walkthroughs_path: "/api/v1/app/chats/#{chat_session.id}/video_walkthroughs",
        app_video_walkthrough_retry_path: "/api/v1/app/video_walkthroughs/:id/retry"
      }
    end

    # Already-analyzed threads keep their history: the list is served whenever
    # the plugin is on, independent of whether this chat can record a new one.
    def self.walkthroughs_json(chat_session)
      chat_session.video_walkthroughs.with_attached_file.newest_first.map do |walkthrough|
        {
          id: walkthrough.id,
          title: walkthrough.display_title,
          state: walkthrough.state,
          duration_seconds: walkthrough.duration_seconds,
          byte_size: walkthrough.byte_size,
          error_message: walkthrough.error_message,
          has_video: walkthrough.file.attached?,
          created_at: walkthrough.created_at.iso8601
        }
      end
    end

    private_class_method :walkthroughs_json
  end
end
