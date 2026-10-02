require "mcp"

module CredentialStore
  class SshExecTool < MCP::Tool
    tool_name SshExec::TOOL_NAME

    description "Run a command over SSH using a credential_store ssh_private_key credential lease. " \
                "The private key is materialized only as a temporary 0600 file, command output is redacted, " \
                "and credential access is audited. Credentials must be constrained by host metadata, known_host, " \
                "or allowed_hosts unless allow_unconstrained_host is explicitly true."

    input_schema(
      type: "object",
      required: [ "credential", "host", "user", "command" ],
      properties: {
        credential: {
          type: [ "integer", "string" ],
          description: "Credential id or unique name for an ssh_private_key credential."
        },
        host: {
          type: "string",
          description: "SSH host to connect to."
        },
        user: {
          type: "string",
          description: "SSH username."
        },
        command: {
          type: "string",
          description: "Remote command to run."
        },
        port: {
          type: "integer",
          minimum: 1,
          maximum: 65_535,
          description: "SSH port. Defaults to ssh's port 22."
        },
        connect_timeout: {
          type: "integer",
          minimum: 1,
          maximum: 120,
          description: "SSH connection timeout in seconds."
        },
        allow_unconstrained_host: {
          type: "boolean",
          description: "Explicitly allow credentials with no host, known_host, or allowed_hosts constraint."
        },
        allow_risky_command: {
          type: "boolean",
          description: "Explicitly allow command patterns that look destructive."
        }
      }
    )

    class << self
      def call(server_context:, credential: nil, host: nil, user: nil, command: nil, port: nil, connect_timeout: nil, allow_unconstrained_host: false, allow_risky_command: false)
        context = McpToolContext.from_server_context(server_context)
        payload = CredentialStore::SshExec.call(
          context: context,
          credential: credential,
          host: host,
          user: user,
          command: command,
          port: port,
          connect_timeout: connect_timeout,
          allow_unconstrained_host: allow_unconstrained_host,
          allow_risky_command: allow_risky_command
        )
        MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ], error: !payload.fetch(:ok))
      rescue CredentialStore::Broker::Error, CredentialStore::SshExec::Error => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
