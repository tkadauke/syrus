module VideoWalkthroughs
  extend Syrus::PluginApi

  syrus_plugin "video_walkthroughs" do
    display_name "Walkthrough Videos"
    description "Record or drag a narrated screen recording into a chat; Gemini analyzes it " \
      "and the chat agent works it toward an Epic."
    long_description "Walkthrough Videos turns a narrated screen recording into work. Drop a video into a chat and Gemini produces a timestamped transcript, topical sections, and grounded issue reports; the chat agent then pulls that report and crisp stills with its own tools and drives toward an Epic through the normal proposal machinery.\n\nGemini is the eyes and the chat agent stays the brain: every step is a real tool call you can trace. Requires a Gemini AI Studio API key per user. Stored videos are pruned on a retention window and an instance-wide storage budget; the analysis and screenshots always persist.\n\nThe desktop app's screen recorder and red-pen annotation overlay ship with the desktop app itself and stay available regardless of this plugin -- what this plugin owns is the intake, analysis, and chat handoff."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/video_walkthroughs.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    # Was a Labs feature flag defaulting off, and a plugin is its own feature
    # flag: the flag is gone and this is what replaced it.
    default_enabled false
    disableable true
    # Gemini uploads and polling run for minutes; they had their own low-
    # concurrency queue in core precisely so they could not pin default
    # threads, and the plugin keeps it.
    home_queue :videos

    provides chat_mcp_tool_set: "VideoWalkthroughs::ChatToolSet",
             chat_payload_contributor: "VideoWalkthroughs::PayloadContributor",
             chat_turn_orientation: "VideoWalkthroughs::TurnOrientation",
             callbacks: "VideoWalkthroughs::Callbacks"

    route :post, "/api/v1/app/chats/:chat_id/video_walkthroughs", to: "api/v1/app/video_walkthroughs#create"
    route :post, "/api/v1/app/video_walkthroughs/:id/retry", to: "api/v1/app/video_walkthroughs#retry"

    # Walkthroughs belong to a chat and a user, and deleting either has to take
    # them (and their blobs) with it whether the plugin is on or not -- a
    # disabled plugin must not leave orphaned 500MB blobs behind.
    always "chat session associations" do |_scope|
      unless ChatSession.reflect_on_association(:video_walkthroughs)
        ChatSession.has_many :video_walkthroughs,
                             class_name: "VideoWalkthroughs::Walkthrough",
                             foreign_key: :chat_session_id,
                             dependent: :destroy
      end
      nil
    end

    while_enabled do |scope|
      # ::CredentialProbe, not CredentialProbe: this block is lexically inside
      # `module VideoWalkthroughs`, which has its own CredentialProbe.
      scope.effect("gemini credential probe") { ::CredentialProbe.register_probe("gemini_api_key", VideoWalkthroughs::CredentialProbe) }
    end

    # Retention is enforced on the plugin's own tick rather than the host's
    # recurring.yml, so removing the plugin removes the schedule with it.
    tick_interval 1.day
  end
end
