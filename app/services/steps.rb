module Steps
  REGISTRY = StepKind.registry

  def self.handler_for(kind)
    StepKind.handler_for(kind)
  rescue ArgumentError
    raise ArgumentError, "no handler for step kind=#{kind.inspect}"
  end
end
