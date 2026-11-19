# How long a SolidQueue worker waits for in-flight jobs after SIGTERM before
# abandoning them. SolidQueue's default is five seconds, so a pod restart
# killed every running job no matter how much termination grace Kubernetes
# allowed. A compute pod that drains while its replacement already serves
# sets this to cover the longest grader (see Syrus::QueueShutdownTimeout).
Rails.application.config.after_initialize do
  if (timeout = Syrus::QueueShutdownTimeout.from_env)
    SolidQueue.shutdown_timeout = timeout
  end
end
