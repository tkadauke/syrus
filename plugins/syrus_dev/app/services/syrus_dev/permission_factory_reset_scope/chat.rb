module SyrusDev
  class PermissionFactoryResetScope::Chat < PermissionFactoryResetScope
    def chat = @chat ||= Syrus::Host::ChatSessionRecord.find(id)
    def users = Syrus::Host::UserRecord.where(id: chat.user_id)
    def leases = Syrus::Host::PermissionLease.where(chat_session_id: chat.id)
    def requests = Syrus::Host::ChatPendingActionRecord.where(request_kind: "authorization_request", chat_session_id: chat.id)
  end
end
