module PendingActions
  # The owner's confirmation card for Coworkers::SpawnChatTool. Registered
  # under the tool's name so core honours the tool's approval_effect: its only
  # mutation before approval is creating this card.
  class SpawnCoworkerChat < CoworkerToolCall
    action_key "spawn_coworker_chat"

    def presentation_label = "Approve coworker side chat"
  end
end
