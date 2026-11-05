module SyrusDev
  class PermissionFactoryResetScope::Chat < PermissionFactoryResetScope
    def chat = @chat ||= ChatSession.find(id)
    def users = ::User.where(id: chat.user_id)
    def leases = PermissionLease.where(chat_session_id: chat.id)
    def requests = ChatPendingAction.where(request_kind: "authorization_request", chat_session_id: chat.id)
  end
end
