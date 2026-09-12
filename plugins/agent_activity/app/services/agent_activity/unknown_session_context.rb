module AgentActivity
  class UnknownSessionContext < SessionContext
    def role_label = @resumable.class.name.demodulize.underscore.humanize
  end
end
