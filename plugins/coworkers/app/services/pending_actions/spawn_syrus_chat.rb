module PendingActions
  # The owner's confirmation card for Coworkers::SpawnSyrusChatTool. Registered
  # under the tool's name so core honours the tool's approval_effect: its only
  # mutation before approval is creating this card.
  class SpawnSyrusChat < CoworkerToolCall
    action_key "spawn_syrus_chat"

    def presentation_label = "Approve coworker engineering chat"
  end
end
