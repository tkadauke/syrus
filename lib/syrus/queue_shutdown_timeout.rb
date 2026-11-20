module Syrus
  # Reads SOLID_QUEUE_SHUTDOWN_TIMEOUT (whole seconds). Absent or invalid
  # leaves SolidQueue's own default in place rather than guessing.
  module QueueShutdownTimeout
    ENV_KEY = "SOLID_QUEUE_SHUTDOWN_TIMEOUT".freeze

    module_function

    def from_env(env = ENV)
      seconds = Integer(env[ENV_KEY].to_s, 10, exception: false)
      seconds&.positive? ? seconds.seconds : nil
    end
  end
end
