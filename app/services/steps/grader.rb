module Steps
  # Executes one grader command, captures its output, transitions the
  # Step accordingly. Per-grader-Step replacement for the inner loop
  # that lived in Steps::Grade — one Step per grader instead of one
  # Step per fanout. Grader Step failure does NOT cascade to a
  # workflow fail; StepDispatcher recognizes kind "grader" as a
  # silent-failure kind and advances to the next sibling regardless
  # of outcome. The iteration's grader_collect Step is what
  # aggregates pass/fail and triggers loop iteration if needed.
  #
  # Grader definition (name, command, description, required,
  # timeout_minutes) lives on Step#details — captured at materialize
  # time by Steps::GraderFanout, immutable for this Step. .syrus.yml
  # can evolve over the workflow's lifetime without re-interpreting
  # historical Steps.
  class Grader < Base
    TIMEOUT_EXIT_CODE = 124
    OUTPUT_INLINE_BYTES = 16 * 1024

    def call
      workspace.setup

      definition = step.details || {}
      name = definition.fetch("name") { raise StepFailed, "grader Step missing details[name]" }
      command = definition.fetch("command") { raise StepFailed, "grader Step missing details[command]" }
      timeout_minutes = (definition["timeout_minutes"] || 15).to_i

      # Augment rspec commands with a structured output file so failure
      # details survive even when stdout is cut off mid-output (OOM, signal).
      json_results_path = nil
      if command.include?("rspec") && !command.include?("--format json")
        json_results_path = Rails.root.join("tmp", "rspec_grade_#{SecureRandom.hex(8)}.json").to_s
        command = "#{command} --format json --out #{json_results_path}"
      end

      log("[grader:#{name}] $ #{command}")

      log_path = grader_log_path(name)
      absolute_log_path = workspace.path.join(log_path)
      FileUtils.mkdir_p(absolute_log_path.dirname)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      exit_code = nil
      timed_out = false

      line_buffer = +""

      File.open(absolute_log_path, "wb") do |file|
        result = ProcessRunner.new(
          env: env,
          command: [ "bash", "-c", command ],
          chdir: workspace.path,
          timeout: timeout_minutes.minutes,
          kind: "grader",
          run: run,
          workflow: workflow,
          on_output_chunk: ->(chunk) do
            file.write(chunk)
            file.flush
            line_buffer << chunk
            while (nl = line_buffer.index("\n"))
              log(line_buffer.slice!(0..nl), kind: "grade_log")
            end
          end
        ).run

        timed_out = result.timed_out
        exit_code = timed_out ? TIMEOUT_EXIT_CODE : result.exit_status

        if timed_out
          file.write("\n[timed out after #{timeout_minutes} minutes]\n")
          log("[grader:#{name}] timed out after #{timeout_minutes} minutes")
        end
      end

      log(line_buffer, kind: "grade_log") if line_buffer.present?

      duration_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      passed = exit_code.to_i.zero?

      # Snapshot the result onto Step#details so the UI + agent
      # prompt can render it later without re-reading the log file
      # (workspace gets pruned). Keep the per-grader log on disk
      # too, for full output when the operator drills in.
      output_excerpt = grader_output_excerpt(absolute_log_path)
      step.update!(details: definition.merge(
        "exit_code" => exit_code,
        "duration_s" => duration_s.round(1),
        "timed_out" => timed_out,
        "log_path" => log_path.to_s,
        "log_bytes" => absolute_log_path.size,
        "output" => output_excerpt
      ))

      # When RSpec exits with failures, supplement the transcript with
      # structured details from the JSON formatter — available even if
      # stdout was cut off before the summary printed.
      if !passed && json_results_path && File.exist?(json_results_path)
        begin
          results = JSON.parse(File.read(json_results_path))
          failures = results.dig("examples")&.select { |e| e["status"] == "failed" } || []
          if failures.any?
            log("[rspec failures from JSON output]\n", kind: "grade_log")
            failures.each do |f|
              log("#{f["full_description"]}\n", kind: "grade_log")
              log("  #{f.dig("exception", "message")}\n", kind: "grade_log") if f.dig("exception", "message")
              log("  #{f["location"]}\n", kind: "grade_log") if f["location"]
            end
          end
        rescue JSON::ParserError
          # partial write — ignore
        ensure
          File.delete(json_results_path) rescue nil
        end
      end

      ingest_test_output!(name, definition["junit_output"]) if definition["junit_output"].present?

      raise StepFailed, "grader #{name} failed (exit #{exit_code})" unless passed
    end

    private

    def grader_log_path(name)
      Pathname.new(".syrus/grade-output/iteration-#{run.iteration}/#{name}.log")
    end

    def grader_output_excerpt(path)
      return "" unless path.exist?
      output = path.binread
      output = output.safe_byteslice(-OUTPUT_INLINE_BYTES, OUTPUT_INLINE_BYTES) if output.bytesize > OUTPUT_INLINE_BYTES
      output.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
    end

    def ingest_test_output!(grader_name, output_path_str)
      absolute_path = workspace.path.join(output_path_str)
      unless absolute_path.exist?
        log("[grader:#{grader_name}] junit_output #{output_path_str.inspect} not found — skipping ingestion")
        return
      end

      parsed = try_plugin_parsers(absolute_path) || JunitXmlParser.parse(absolute_path.read)
      TestRunIngester.new(run: run, grader_name: grader_name, parsed_run: parsed).ingest!
      log("[grader:#{grader_name}] ingested #{parsed.total_count} test case(s) from #{output_path_str}")
    rescue JunitXmlParser::ParseError => e
      log("[grader:#{grader_name}] warning: JUnit XML parse error: #{e.message}")
    rescue StandardError => e
      log("[grader:#{grader_name}] warning: test output ingestion failed: #{e.class}: #{e.message}")
    end

    def try_plugin_parsers(absolute_path)
      Syrus::PluginRegistry.providers_for(:test_result_parser).each do |provider|
        return provider.call(output_path: absolute_path) if provider.can_parse?(output_path: absolute_path)
      end
      nil
    end

    def env
      ProcessRunner.forwarded_env(Prepare::PREP_ENV_FORWARD)
    end
  end
end
