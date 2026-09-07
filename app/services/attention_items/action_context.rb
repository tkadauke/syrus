module AttentionItems
  # The `action` argument `PendingActions::Base` subclasses expect --
  # `payload`/`reason`/`user`/`repository`/`chat_session`/`id` -- built
  # without a `ChatPendingAction` row. `ChatPendingAction` is the confirmation
  # flow chat proposals use; it requires a `chat_session`, which an
  # AttentionItem (opened by a backend producer, not a chat turn) does not
  # have. This is the same typed-command contract, constructed for a
  # non-chat caller.
  class ActionContext
    attr_reader :payload, :reason, :user, :repository, :chat_session, :id

    def initialize(payload:, user: nil, reason: nil, repository: nil, id: nil)
      @payload = payload.to_h
      @reason = reason
      @user = user
      @repository = repository
      @chat_session = nil
      @id = id
    end

    # Most `PendingActions::*#execute` implementations report progress via
    # `PendingActions::Base#progress!`, which persists a status string onto
    # the acting `ChatPendingAction` row for the chat UI to poll. There is no
    # row here to update and nothing polling it -- a synchronous admin
    # request either finishes or fails within one HTTP round trip.
    def update_confirmation_progress!(_status, _step)
      nil
    end
  end
end
