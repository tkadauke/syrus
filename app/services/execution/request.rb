module Execution
  Request = Data.define(
    :env,
    :command,
    :chdir,
    :mounts,
    :network,
    :resource_limits,
    :timeout,
    :stdin_data,
    :unsetenv_others,
    :pgroup,
    :stop_requested,
    :on_output_chunk,
    :on_output_line,
    :kill_grace_seconds,
    :silent_timeout,
    :kind,
    :run,
    :workflow,
    :job,
    :chat_session,
    :agent,
    :display_command,
    :on_spawned_process,
    :local_runner
  )
end
