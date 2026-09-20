module PendingActions
  class ArchiveEpic < Base
    action_key "archive_epic"

    def execute
      epic = action_epic
      raise ArgumentError, "epic is already archived" if epic.archived?

      progress!("Archiving #{epic.slug} and closing open child Jobs...")
      epic.archive!
      epic
    end

    def execution_label
      "Archiving epic..."
    end

    def validate_payload(errors)
      errors.add(:payload, "epic_id is required") unless payload["epic_id"].present?
    end

    def action_detail
      "epic_id: #{payload["epic_id"]}"
    end

    def presentation_label
      "Archive Epic ##{payload["epic_id"]}"
    end

    private

    def action_epic
      scope = user.admin? ? Epic.all : Epic.accessible_to(user)
      scope = scope.where(repository: repository) if repository && !user.admin?
      scope.find(payload.fetch("epic_id"))
    end
  end
end
