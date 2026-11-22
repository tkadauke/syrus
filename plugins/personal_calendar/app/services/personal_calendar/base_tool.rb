require "mcp"
module PersonalCalendar
  class BaseTool < MCP::Tool
    class << self
      def invoke(capability, server_context:, arguments:)
        context = McpToolContext.from_server_context(server_context)
        account = ConnectedAccounts::Account.find_by(id: arguments.fetch(:account_id), owner_user_id: context.user&.id)
        raise ConnectedAccounts::AccountClient::Denied, "connected account not found" unless account
        result = ConnectedAccounts::AccountClient.with_access(account:, acting_mode: arguments.fetch(:acting_mode),
          scopes: [ "calendar.read" ], purpose: "Read calendar", context:, target: {}) do |access|
          Syrus::Host::CapabilityDispatch.call(:personal_calendar, capability,
            Context.new(account:, access:, arguments: arguments.stringify_keys), key: account.provider)
        end
        Mcp::Tools.success(ResultShaper.call(result, context:))
      rescue ConnectedAccounts::AccountClient::Denied, Syrus::Host::CapabilityDispatch::MissingKey, KeyError => error
        Mcp::Tools.invalid(error.message)
      end
    end
  end
end
