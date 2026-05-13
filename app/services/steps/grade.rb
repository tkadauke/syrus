require "open3"

module Steps
  class Grade < Base
    TIMEOUT_EXIT_CODE = 124
    SKIPPED_REASON = "earlier required grader failed".freeze

    def call
      workspace.setup
      plan = RepoGradePlan.for(workspace.path)

      log("[grade] source: #{plan.source}")
      log("[grade] note: #{plan.note}") if plan.note

      if plan.graders.empty?
        log("[grade] no graders configured")
        return
      end

      required_failed = false
      results = plan.graders.map do |grader|
        if required_failed
          skipped_result(grader, reason: SKIPPED_REASON)
        else
          result = run_grader(grader)
          required_failed ||= grader.required && result["status"] == "failed"
          result
        end
      end

      append_iteration_results!(results)

      raise StepFailed, "required grader failed" if results.any? { |result| result["required"] && result["status"] == "failed" }

      log("[grade] all required graders passed")
    end

    private

    def run_grader(grader)
      log("[grade] $ #{grader.command}")
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      timed_out = false
      exit_code = nil
      log_path = grader_log_path(grader)
      absolute_log_path = workspace.path.join(log_path)
      FileUtils.mkdir_p(absolute_log_path.dirname)

      File.open(absolute_log_path, "wb") do |file|
        Open3.popen2e(env, "bash", "-c", grader.command,
                      chdir: workspace.path.to_s,
                      unsetenv_others: true,
                      pgroup: true) do |stdin, output, wait_thread|
          stdin.close
          killer = timeout_thread(wait_thread.pid, grader.timeout_minutes) { timed_out = true }

          stream_to_file(output, file)

          killer.kill
          status = wait_thread.value
          exit_code = timed_out ? TIMEOUT_EXIT_CODE : (status.exitstatus || 1)
        end

        if timed_out
          file.write("\n[timed out after #{grader.timeout_minutes} minutes]\n")
          log("[grade] #{grader.name} timed out after #{grader.timeout_minutes} minutes")
        end
      end

      duration_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      status = exit_code.to_i.zero? ? "passed" : "failed"

      result_for(grader,
                 status: status,
                 exit_code: exit_code,
                 duration_s: duration_s,
                 log_path: log_path)
    end

    def skipped_result(grader, reason:)
      log_path = grader_log_path(grader)
      absolute_log_path = workspace.path.join(log_path)
      FileUtils.mkdir_p(absolute_log_path.dirname)
      File.write(absolute_log_path, "[skipped: #{reason}]\n")

      result_for(grader,
                 status: "skipped",
                 exit_code: nil,
                 duration_s: 0.0,
                 log_path: log_path,
                 reason: reason)
    end

    def result_for(grader, status:, exit_code:, duration_s:, log_path:, reason: nil)
      absolute_log_path = workspace.path.join(log_path)
      {
        "name" => grader.name,
        "required" => grader.required,
        "status" => status,
        "exit_code" => exit_code,
        "duration_s" => duration_s.round(1),
        "log_path" => log_path.to_s,
        "log_bytes" => absolute_log_path.size
      }.tap do |result|
        result["reason"] = reason if reason
      end
    end

    def append_iteration_results!(results)
      iterations = Array(workflow.artifact("iterations"))
      index = run.iteration - 1
      iterations[index] = Array(iterations[index]) + results
      workflow.set_artifact!("iterations", iterations)
    end

    def grader_log_path(grader)
      Pathname.new(".syrus/grade-output/iteration-#{run.iteration}/#{grader.name}.log")
    end

    def env
      ENV.slice(*Prepare::PREP_ENV_FORWARD)
    end

    def timeout_thread(pid, timeout_minutes)
      Thread.new do
        sleep timeout_minutes.minutes
        yield
        kill_tree(pid)
      end
    end

    def stream_to_file(output, file)
      loop do
        ready, = IO.select([ output ], nil, nil, 0.5)
        next unless ready

        begin
          chunk = output.read_nonblock(16 * 1024)
          file.write(chunk)
          file.flush
        rescue IO::WaitReadable
          next
        rescue EOFError
          break
        end
      end
    end

    def kill_tree(pid)
      Process.kill("TERM", -pid)
      sleep 5
      Process.kill("KILL", -pid) rescue nil
    rescue Errno::ESRCH
      # Already dead.
    end
  end
end
