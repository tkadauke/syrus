# How long a SolidQueue worker waits for in-flight jobs after SIGTERM before
# abandoning them. SolidQueue's default is five seconds, so a pod restart
# killed every running job no matter how much termination grace Kubernetes
# allowed. A compute pod that drains while its replacement already serves
# sets this to cover the longest grader (see Syrus::QueueShutdownTimeout).
Rails.application.config.after_initialize do
  if (timeout = Syrus::QueueShutdownTimeout.from_env)
    SolidQueue.shutdown_timeout = timeout
  end

  # Stop routing new work to a worker the moment it starts draining (see
  # Syrus::QueueDrain). The hook runs as the worker stops polling, before it
  # waits out its in-flight jobs.
  SolidQueue.on_worker_stop { |worker| Syrus::QueueDrain.mark_process_id!(worker.process_id) }
end
