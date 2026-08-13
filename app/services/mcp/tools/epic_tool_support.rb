module Mcp::Tools
  module EpicToolSupport
    private

    def normalize_epic_id(value)
      Integer(value, exception: false)
    end

    def find_repository_epic(chat_session, epic_id)
      return unless epic_id

      scope = chat_session.user.admin? ? Epic.all : chat_session.repository.epics
      scope.find_by(id: epic_id)
    end

    def epic_not_found(epic_id)
      Mcp::Tools.invalid("epic not found in this repository: #{epic_id}")
    end

    def compact_epic_payload(epic)
      {
        epic_id: epic.id,
        title: epic.title.to_s,
        description: epic.description.to_s,
        state: epic.state
      }
    end

    def truncated_description(epic)
      epic.description.to_s.each_char.take(200).join
    end
  end
end
