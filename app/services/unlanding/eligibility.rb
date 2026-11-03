module Unlanding
  # Shared guard for *creating* new unland operations. Every entry point
  # (App API, Syrus Chat MCP tools, pending-action confirmation, Unlanding::Create)
  # converges here. It deliberately does not gate anything about existing
  # rollback Jobs or unland Workflows, which must stay visible and able to finish.
  module Eligibility
    class Disabled < StandardError
      def initialize(message = I18n.t("unlanding.disabled"))
        super
      end
    end

    module_function

    def enabled? = Feature.unlanding_enabled?

    def ensure_enabled!
      raise Disabled unless enabled?
    end
  end
end
