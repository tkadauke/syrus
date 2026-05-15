module Steps
  REGISTRY = Step::Kind.registry

  def self.handler_for(kind)
    Step::Kind.handler_for(kind)
  rescue ArgumentError
    raise ArgumentError, "no handler for step kind=#{kind.inspect}"
  end
end
