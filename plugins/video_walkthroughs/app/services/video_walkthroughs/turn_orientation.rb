module VideoWalkthroughs
  # A walkthrough-video message triggers the FIRST-CLASS handoff: rather than
  # dumping the analysis in as a fake user message, orient the agent to pull it
  # with its own tools (get_walkthrough_analysis / read_walkthrough_frame) and
  # work autonomously toward an Epic. Every step is then a real tool call you
  # can trace, which a pasted blob would not be.
  module TurnOrientation
    include Syrus::Plugin::ChatTurnOrientation

    # Returns nil for a normal message, and for a walkthrough row that has
    # vanished -- the turn falls through to whatever note the user typed rather
    # than failing, which is what they meant either way.
    def self.chat_turn_orientation(chat_session:, message:, user_note:)
      return nil unless message.content.is_a?(Hash)

      walkthrough_id = message.content["video_walkthrough_id"]
      return nil if walkthrough_id.blank?

      walkthrough = Walkthrough.find_by(id: walkthrough_id)
      return nil unless walkthrough

      Prompts::Context.new(walkthrough: walkthrough, user_note: user_note).to_s
    end
  end
end
