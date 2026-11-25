module RuntimeImages
  # Base class every storage backend implements. Methods receive and return
  # the value objects in contract.rb; a provider that cannot support an
  # operation raises Unsupported rather than returning a partial answer.
  class Provider
    def key
      raise NotImplementedError, "#{self.class.name} must implement #key"
    end

    # publish must be idempotent per digest and must never clear a prior
    # revocation; the service re-asserts revoke/delete if it does.
    def publish(_request) = raise(NotImplementedError, "#{self.class.name} must implement #publish")
    def resolve(_request) = raise(NotImplementedError, "#{self.class.name} must implement #resolve")
    def inspect_image(_request) = raise(NotImplementedError, "#{self.class.name} must implement #inspect_image")
    def pull(_request) = raise(NotImplementedError, "#{self.class.name} must implement #pull")
    def revoke(_request) = raise(NotImplementedError, "#{self.class.name} must implement #revoke")
    def retain(_request) = raise(NotImplementedError, "#{self.class.name} must implement #retain")
    def delete(_request) = raise(NotImplementedError, "#{self.class.name} must implement #delete")

    # Optional: the digests the backing store holds for one namespace
    # (Array<String>), used to find objects with no durable record. Providers
    # that cannot enumerate keep this default and reconciliation reports the
    # namespace as unsupported rather than guessing.
    def list(_request) = raise(Unsupported, "#{self.class.name} cannot list a namespace's digests")
  end
end
