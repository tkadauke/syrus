class Coworkers::ChatResultDecorator
  include Syrus::Plugin::ChatResultDecorator

  def self.chat_result_badges(chat_sessions:)
    ids = chat_sessions.map(&:id)
    return {} if ids.empty?

    Coworkers::Chat
      .joins(:coworker)
      .where(chat_session_id: ids)
      .pluck(:chat_session_id, :coworker_id, "coworkers.name")
      .to_h { |chat_session_id, coworker_id, name| [ chat_session_id, [ { kind: "coworker", id: coworker_id, name: name } ] ] }
  end
end
