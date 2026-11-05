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
end
