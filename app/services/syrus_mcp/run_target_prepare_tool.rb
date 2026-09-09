require "mcp"

module SyrusMcp
  # Lets an implementation agent explicitly run one compiled TargetGraph
  # prepare target after it discovers that a project-specific environment is
  # needed. Root prepare remains the only automatic pre-implementation prepare.
  class RunTargetPrepareTool < MCP::Tool
    tool_name "run_target_prepare"

    OUTPUT_TAIL_BYTES = 8.kilobytes
    ARTIFACT_KEY = "target_prepare_requests".freeze

    description <<~DESC
      Run a compiled TargetGraph prepare target in the current workflow workspace.
      Use this only when the implementation needs a project-specific environment
      beyond the root prepare that Syrus already ran automatically. The target
      must be a prepare target shown in the agent environment snapshot.
    DESC

    input_schema(
      properties: {
        label: {
          type: "string",
          description: "TargetGraph label of the prepare target to run, e.g. //cli:prepare."
        },
        reason: {
          type: "string",
          description: "Short reason this target-specific prepare is needed."
        }
      },
      required: %w[label]
    )

    class << self
      def call(label:, reason: nil, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :run_target_prepare)

        workspace_path = WorkflowWorkspace.path_for(run.workflow)
        return Mcp::Tools.invalid("no workflow workspace found") unless workspace_path.directory?

        parsed_label = parse_label(label)
        return parsed_label if parsed_label.is_a?(MCP::Tool::Response)

        graph = TargetGraph::Compiler.compile(workspace_path)
        target = graph.target(parsed_label)
        return Mcp::Tools.invalid("unknown target #{parsed_label}") unless target
        return Mcp::Tools.invalid("#{parsed_label} is a #{target.kind} target, not a prepare target") unless target.kind == "prepare"
        return Mcp::Tools.invalid("#{parsed_label} has no command to run") unless target.executable?

        project = graph.project(target.project_id)
        workdir = workspace_path.join(project&.path.to_s)
        return Mcp::Tools.invalid("target project path does not exist: #{project&.path}") unless workdir.directory?

        commands = commands_for(target)
        request = base_request(run, target, workdir, commands, reason)
        append_request!(run.workflow, request.merge("status" => "started"))
        Mcp::Tools.write_log(run, "[mcp] run_target_prepare requested: #{target.label}#{reason_suffix(reason)}")

        result = run_commands(run, commands, workdir, target)
        final_request = request.merge(result)
        replace_last_request!(run.workflow, final_request)

        response = { "text" => target.label.to_s, "result" => final_request }
        if result["status"] == "succeeded"
          MCP::Tool::Response.new([ { type: "text", text: JSON.generate(response) } ])
        else
          MCP::Tool::Response.new([ { type: "text", text: JSON.generate(response) } ], error: true)
        end
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::RunTargetPrepareTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def parse_label(label)
        TargetGraph::Label.parse(Mcp::Tools.utf8(label).strip)
      rescue TargetGraph::Label::ParseError => e
        Mcp::Tools.invalid(e.message)
      end

      def commands_for(target)
        Array(target.metadata["commands"]).presence || [ target.command ]
      end

      def base_request(run, target, workdir, commands, reason)
        {
          "label" => target.label.to_s,
          "reason" => Mcp::Tools.utf8(reason).strip.presence,
          "commands" => commands,
          "workdir" => workdir.to_s,
          "owner_config_path" => target.owner_config_path,
          "project_id" => target.project_id,
          "run_id" => run.id,
          "started_at" => Time.current.iso8601
        }.compact
      end

      def run_commands(run, commands, workdir, target)
        output_tail = +""
        command_results = []

        commands.each_with_index do |command, index|
          Mcp::Tools.write_log(run, "[mcp] run_target_prepare #{target.label} (#{index + 1}/#{commands.size}) $ #{command}")
          result = ProcessRunner.new(
            env: process_env(run.workflow),
            command: [ "bash", "-c", command ],
            chdir: workdir.to_s,
            timeout: Steps::Prepare::PER_COMMAND_TIMEOUT,
            kind: "prepare",
            run: run,
            workflow: run.workflow,
            display_command: "run_target_prepare #{target.label}: #{command}",
            on_output_chunk: ->(chunk) {
              append_output_tail(output_tail, chunk)
              Mcp::Tools.write_log(run, chunk)
            }
          ).run
          command_results << result_payload(command, result)
          return failure_payload(command_results, output_tail) unless result.success?
        end

        {
          "status" => "succeeded",
          "finished_at" => Time.current.iso8601,
          "command_results" => command_results,
          "output_tail" => compact_output_tail(output_tail)
        }
      end

      def result_payload(command, result)
        {
          "command" => command,
          "exit_status" => result.exit_status,
          "timed_out" => result.timed_out?,
          "stopped" => result.stopped?,
          "operator_killed" => result.operator_killed?,
          "aliveness_failed" => result.aliveness_failed?,
          "duration_s" => result.duration_s&.round(2)
        }
      end

      def failure_payload(command_results, output_tail)
        {
          "status" => "failed",
          "finished_at" => Time.current.iso8601,
          "command_results" => command_results,
          "output_tail" => compact_output_tail(output_tail)
        }
      end

      def process_env(workflow)
        workspace_path = WorkflowWorkspace.path_for(workflow)
        extra = WorkspaceDependencyEnv.for(workspace_path).merge(
          Steps::Prepare.prep_extra_env(workflow: workflow, workspace_path: workspace_path)
        )
        ProcessRunner.forwarded_env(Steps::Prepare.prep_env_forward, extra: extra)
      end

      def append_request!(workflow, request)
        workflow.set_artifact!(ARTIFACT_KEY, [ *Array(workflow.artifact(ARTIFACT_KEY)), request ])
      end

      def replace_last_request!(workflow, request)
        requests = Array(workflow.artifact(ARTIFACT_KEY))
        requests[-1] = request
        workflow.set_artifact!(ARTIFACT_KEY, requests)
      end

      def append_output_tail(output_tail, chunk)
        output_tail << chunk.to_s
        output_tail.replace(output_tail.safe_byteslice(-OUTPUT_TAIL_BYTES, OUTPUT_TAIL_BYTES)) if output_tail.bytesize > OUTPUT_TAIL_BYTES
      end

      def compact_output_tail(output)
        output.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?").strip
      end

      def reason_suffix(reason)
        clean = Mcp::Tools.utf8(reason).strip
        clean.present? ? " reason=#{clean.inspect}" : ""
      end
    end
  end
end
