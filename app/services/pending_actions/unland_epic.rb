module PendingActions
  class UnlandEpic < Base
    action_key "unland_epic"

    def execute
      epic = Epic.find(payload.fetch("epic_id"))
      progress!("Creating linked rollback for #{epic.slug}...")
      Unlanding::Create.call!(original: epic, user: user)
    end

    def validate_payload(errors)
      errors.add(:payload, "epic_id is required") unless payload["epic_id"].present?
    end

    def presentation_label = "Unland Epic"
    def presentation_detail = "epic_id: #{payload['epic_id']}"
  end
end
