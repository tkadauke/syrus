module SyrusDev
  class PermissionFactoryResetScope
    attr_reader :id

    def self.for(type, id: nil)
      scope_class = types.fetch(type.to_s) { raise ArgumentError, "unknown permission reset scope" }
      scope_class.new(id:)
    end

    def self.types
      {
        "chat" => Chat,
        "actor" => Actor,
        "user" => User,
        "repository" => Repository,
        "instance" => Instance
      }.freeze
    end

    def initialize(id: nil)
      @id = id.presence
      validate!
    end

    def key = self.class.name.demodulize.underscore
    def users = ::User.none
    def profile_users = users
    def rules = PermissionRule.none
    def leases = PermissionLease.none
    def requests = ChatPendingAction.none

    private

    def validate!
      raise ArgumentError, "#{key} scope requires an id" if id.blank?
    end
  end

  class PermissionFactoryResetScope::Chat < PermissionFactoryResetScope
    def chat = @chat ||= ChatSession.find(id)
    def users = ::User.where(id: chat.user_id)
    def leases = PermissionLease.where(chat_session_id: chat.id)
    def requests = ChatPendingAction.where(request_kind: "authorization_request", chat_session_id: chat.id)
  end

  class PermissionFactoryResetScope::Actor < PermissionFactoryResetScope
    def actor = @actor ||= GlobalID::Locator.locate(id) || raise(ActiveRecord::RecordNotFound)
    def users = ::User.where(id: actor.respond_to?(:user_id) ? actor.user_id : actor.id)
    def rules
      PermissionRule.where(subject_selector_type: "agent", subject_selector_id: actor.id.to_s)
    end
    def leases
      PermissionLease.where(subject_selector_type: "agent", subject_selector_id: actor.id.to_s)
    end
    def requests = ChatPendingAction.where(request_kind: "authorization_request", subject: actor)
  end

  class PermissionFactoryResetScope::User < PermissionFactoryResetScope
    def user = @user ||= ::User.find(id)
    def users = ::User.where(id: user.id)
    def profile_users = users
    def rules = PermissionRule.where(owner_user_id: user.id)
    def leases = PermissionLease.where(owner_user_id: user.id)
    def requests = ChatPendingAction.where(request_kind: "authorization_request", user_id: user.id)
  end

  class PermissionFactoryResetScope::Repository < PermissionFactoryResetScope
    def repository = @repository ||= ::Repository.find(id)
    def users
      ::User.where(id: rules.select(:owner_user_id))
        .or(::User.where(id: leases.select(:owner_user_id)))
        .or(::User.where(id: requests.select(:user_id)))
    end
    def rules = PermissionRule.where(subject_repository_id: repository.id)
    def leases = PermissionLease.where(subject_repository_id: repository.id)
    def requests = ChatPendingAction.where(request_kind: "authorization_request", repository_id: repository.id)
  end

  class PermissionFactoryResetScope::Instance < PermissionFactoryResetScope
    def users = ::User.all
    def profile_users = users
    def rules = PermissionRule.all
    def leases = PermissionLease.all
    def requests = ChatPendingAction.where(request_kind: "authorization_request")

    private

    def validate!
      raise ArgumentError, "instance scope does not accept an id" if id.present?
    end
  end
end
