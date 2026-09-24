require "mcp"

module Mcp::Tools
  # MCP tool for an agent investigating a required-grader failure to record
  # a structured, auditable "I ran this exact failing example against this
  # exact failing SHA in isolation, and it did/did not reproduce" fact --
  # before making any fix commits.
  #
  # This is deliberately not a place to self-report an opinion that a test is
  # flaky (Syrus already rejected that idea elsewhere as unverifiable and
  # incentive-correlated). IsolatedReproRecorder does the actual validation:
  # the SHA is read from git, not trusted from the caller, and the test has
  # to be among what the grader actually reported failing. See that class for
  # the full guardrail rationale.
  class RecordIsolatedReproTool < MCP::Tool
    tool_name "record_isolated_repro"

    description <<~DESC
      Call this when investigating a required-grader failure and you run the
      exact failing example in isolation, against the exact failing commit,
      BEFORE making any fix. Records the exact command and its raw output as
      structured evidence -- not a summary or an opinion. Only call this for
      a specific failing example you actually ran in isolation, not a broad
      rerun of the whole grader (a broad rerun that happens to pass is just a
      second grader execution and needs no special recording). The record is
      rejected if your workspace has already moved past the failing commit
      (e.g. because you already made a fix commit) or if the test named
      isn't among what the grader actually reported failing.
    DESC

    input_schema(
      properties: {
        grader_name: {
          type: "string",
          description: "Name of the required grader (as configured in .syrus.yml) whose failure you are investigating."
        },
        suite_name: {
          type: "string",
          description: "Suite/file/class the failing example belongs to, exactly as the grader reported it."
        },
        name: {
          type: "string",
          description: "The failing example's name, exactly as the grader reported it."
        },
        reproduced: {
          type: "boolean",
          description: "Whether running this exact example in isolation, against the exact failing commit, reproduced the failure."
        },
        command: {
          type: "string",
          description: "The exact command you ran to reproduce the example in isolation."
        },
        output: {
          type: "string",
          description: "The raw output (stdout/stderr) from that command."
        },
        exit_status: {
          type: "integer",
          description: "The exit status of that command, if known."
        }
      },
      required: %w[grader_name suite_name name reproduced command output]
    )

    class << self
      def call(grader_name:, suite_name:, name:, reproduced:, command:, output:, exit_status: nil, server_context:)
        run = Mcp::Tools.run_from_context(server_context)

        result = IsolatedReproRecorder.call(
          run: run,
          grader_name: Mcp::Tools.utf8(grader_name),
          suite_name: Mcp::Tools.utf8(suite_name),
          name: Mcp::Tools.utf8(name),
          reproduced: reproduced,
          command: Mcp::Tools.utf8(command),
          output: Mcp::Tools.utf8(output),
          exit_status: exit_status
        )

        return Mcp::Tools.invalid(result.error) unless result.ok?

        Mcp::Tools.write_log(
          run,
          "[mcp] record_isolated_repro: #{result.evidence[:suite_name]}##{result.evidence[:name]} " \
          "at #{result.evidence[:sha].to_s.first(9)} reproduced=#{result.evidence[:reproduced]}"
        )

        Mcp::Tools.success(status: "recorded", evidence: result.evidence)
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::RecordIsolatedReproTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
