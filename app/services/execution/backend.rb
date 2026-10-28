module Execution
  class Backend
    def run(_request)
      raise NotImplementedError, "#{self.class.name} must implement #run"
    end
  end
end
