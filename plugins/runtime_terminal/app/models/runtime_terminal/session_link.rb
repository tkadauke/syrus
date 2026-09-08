module RuntimeTerminal
  class SessionLink < ApplicationRecord
    self.table_name = "runtime_terminal_session_links"

    belongs_to :runtime_session
    belongs_to :terminal_session, class_name: "Terminal::Session"

    validates :runtime_session_id, uniqueness: true
    validates :terminal_session_id, uniqueness: true
  end
end
