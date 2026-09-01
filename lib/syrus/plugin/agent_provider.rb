module Syrus
  module Plugin
    # Interface module for agent provider implementations.
    #
    # Include this module in any class registered as an :agent_provider
    # extension point. The class must implement:
    #
    #   .provider_key   → String  – unique stable identifier (e.g. "claude")
    #   .display_name   → String  – shown in the settings UI
    #   .available?     → bool    – true when the provider is configured
    #   #invoke(job:, step:, workspace:, &block) – streams agent output
    #
    module AgentProvider
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Optional provider-specific hooks. Concrete providers can override
        # these; the defaults keep minimal plugin providers usable.
        def mcp_tool_name(_tool_name, server_name:)
        end

        def evidence_reset_at(_evidence)
        end

        def false_positive_evidence?(_evidence)
          false
        end

        def suppress_usage_limit_run?(_run, model:, observed_at:)
          false
        end

        def ignore_model_for_positive_evidence?(_model)
          false
        end

        def usage_signal_account_id(_user)
        end

        def usage_snapshot(user:, evidence:)
          evidence&.details&.dig("snapshot") || {}
        end

        def usage_status(user:, evidence:)
          evidence&.status
        end

        def usage_observed_at(user:, evidence:)
          evidence&.observed_at&.iso8601
        end

        def availability_evidence_observed_at(user:, latest_evidence:)
          latest_evidence&.observed_at
        end

        def usage_windows(snapshot, observed_at:, now:)
          [ snapshot["primary"], snapshot["secondary"] ].compact.each_with_object({}) do |window, memo|
            label = window["label"].to_s
            key = case label
            when "5h" then "five_hour"
            when "weekly" then "weekly"
            else next
            end
            memo[key] = {
              label: label,
              remaining_percent: window["remaining_percent"],
              used_percent: window["used_percent"],
              reset_at: window["reset_at"]
            }.compact
          end
        end
      end
    end
  end
end
