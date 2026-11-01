class Coworkers::ChatRepositoryDefaultFilter
  include Syrus::Plugin::ChatRepositoryDefaultFilter

  def self.apply(scope:)
    scope.where.not(id: Coworkers::Chat.select(:chat_session_id))
  end
end
