require "mcp"

module Coworkers
  module EnvironmentTools
    class Base < MCP::Tool
      class << self
        def coworker_capability = EnvironmentPermissionProvider::CAPABILITY

        def permission_descriptor(operation)
          EnvironmentPermissionProvider.permission_capability_descriptors.find do |descriptor|
            descriptor.operation == EnvironmentPermissionProvider.operation(operation)
          end || raise("coworker environment permission descriptor is unavailable")
        end

        def context(server_context)
          tool_context = Syrus::Host::ToolContext.from_server_context(server_context)
          coworker = tool_context.agent_actor
          raise ArgumentError, "this tool is only available to a coworker" unless coworker.is_a?(Coworkers::Coworker)

          [ tool_context, coworker ]
        end

        def environment!(coworker)
          coworker.environment || raise(ArgumentError, "the coworker has no environment source yet")
        end

        def ensure_enabled!
          return if Feature.coworker_custom_environments_enabled?

          raise EnvironmentBuildRequest::Disabled, "custom environments are disabled; ask an administrator to enable the experimental feature after its prerequisites are healthy"
        end

        def success(environment, **extra)
          snapshot = EnvironmentInspection.new(environment).call
          Syrus::Host::McpTools.success(environment: EnvironmentInspectionSerializer.new(snapshot).as_json, **extra)
        end

        def safely
          yield
        rescue EnvironmentBuildRequest::Disabled => error
          failure("feature_disabled", error.message, "Ask an administrator to enable coworker custom environments.")
        rescue EnvironmentBuildRequest::BaseUnavailable => error
          failure("base_unavailable", error.message, "Ask an administrator to publish a compatible Syrus coworker base.")
        rescue EnvironmentRevision::InvalidTransition, ActiveRecord::RecordInvalid, ArgumentError => error
          failure("invalid_environment_transition", error.message, "Inspect the environment and retry with an eligible revision.")
        end

        def failure(code, message, next_action)
          MCP::Tool::Response.new([ { type: "text", text: JSON.generate(error: {
            code:, message:, retryable: false, next_action:
          }) } ], error: true)
        end
      end
    end

    class Inspect < Base
      tool_name "inspect_coworker_environment"
      description "Inspect the current coworker environment, candidate build, compatibility, rollback options, and safe failure details. Restricted build and scanner evidence is never returned."
      input_schema(properties: {})

      def self.call(server_context:)
        safely do
          ensure_enabled!
          _tool_context, coworker = context(server_context)
          success(environment!(coworker))
        end
      end
    end

    class RequestBuild < Base
      tool_name "request_coworker_environment_build"
      description "Snapshot the current environment/ files and request an isolated candidate build. Returns immediately with durable build identity and status."
      input_schema(properties: { reason: { type: "string", description: "Why this environment revision is needed." } })

      def self.call(server_context:, reason: nil)
        safely do
          tool_context, coworker = context(server_context)
          result = EnvironmentBuildRequest.new(coworker, Coworkers::Workspace.for(server_context))
            .call(created_by: tool_context.user, reason: reason)
          Syrus::Events.publish("coworker_environment.build_requested", coworker_id: coworker.id,
            environment_id: result.revision.environment_id, revision_id: result.revision.id,
            inspection: EnvironmentInspectionSerializer.new(EnvironmentInspection.new(result.revision.environment).call).as_json)
          success(result.revision.environment, request: result.status)
        end
      end
    end

    class RequestPublication < Base
      tool_name "request_coworker_environment_publication"
      description "Request publication of the verified candidate for future coworker turns. Publication is independently permission checked and never changes a running turn."
      input_schema(properties: { reason: { type: "string" } })

      def self.call(server_context:, reason: nil)
        safely do
          ensure_enabled!
          tool_context, coworker = context(server_context)
          environment = environment!(coworker)
          revision = environment.candidate_revision || raise(ArgumentError, "there is no verified candidate to publish")
          risk = publication_risk(environment, revision)
          authority = EnvironmentPublicationAuthority.new(owner: tool_context.user, coworker:, environment:, revision:,
            risk:, role: tool_context.role, context: { reason: reason }).call
          unless authority.allow?
            kind = authority.ask? ? "approval_required" : "approval_denied"
            Syrus::Events.publish("coworker_environment.#{kind}", coworker_id: coworker.id,
              environment_id: environment.id, revision_id: revision.id,
              inspection: EnvironmentInspectionSerializer.new(EnvironmentInspection.new(environment).call).as_json)
            return failure(authority.ask? ? "approval_required" : "publication_denied",
              authority.ask? ? "publication requires operator confirmation" : "publication is denied by permission policy",
              authority.ask? ? "Ask the owner to approve the publication request." : "Inspect the permission policy or retain the candidate.")
          end
          EnvironmentLifecycle.new(environment).publish!(revision, actor: "coworker:#{coworker.id}", authority:)
          success(environment, published: true)
        end
      end

      def self.publication_risk(environment, revision)
        evidence = revision.build_request&.result&.details.to_h.fetch("evidence", {})
        candidate = EnvironmentPublicationRisk::Snapshot.new(
          source_digest: revision.source_digest, base_digest: revision.base_release&.digest,
          dependency_digest: evidence["dependency_digest"], sbom_digest: evidence["sbom_digest"],
          vulnerabilities: evidence["vulnerabilities"] || {}, secret_findings: evidence["secret_findings"],
          network_sources: evidence["network_sources"] || [], network_policy_digest: evidence["network_policy_digest"],
          policy_digest: evidence["policy_digest"], policy_result: evidence["policy_result"] || "passed",
          image_size: revision.runtime_image&.size_bytes
        )
        active = environment.active_revision
        return EnvironmentPublicationRisk.call(candidate:) unless active

        active_evidence = active.build_request&.result&.details.to_h.fetch("evidence", {})
        previous = EnvironmentPublicationRisk::Snapshot.new(
          source_digest: active.source_digest, base_digest: active.base_release&.digest,
          dependency_digest: active_evidence["dependency_digest"], sbom_digest: active_evidence["sbom_digest"],
          vulnerabilities: active_evidence["vulnerabilities"] || {}, secret_findings: active_evidence["secret_findings"],
          network_sources: active_evidence["network_sources"] || [], network_policy_digest: active_evidence["network_policy_digest"],
          policy_digest: active_evidence["policy_digest"], policy_result: active_evidence["policy_result"] || "passed",
          image_size: active.runtime_image&.size_bytes
        )
        EnvironmentPublicationRisk.call(candidate:, active: previous)
      end
    end

    class RequestRollback < Base
      tool_name "request_coworker_environment_rollback"
      description "Request an atomic rollback to the latest compatible, verified, non-revoked retained environment revision."
      input_schema(properties: {
        revision_id: { type: "integer", description: "A revision_id returned in retained_rollback_digests by inspection." },
        reason: { type: "string" }
      }, required: %w[revision_id reason])

      def self.call(server_context:, revision_id:, reason:)
        safely do
          ensure_enabled!
          _tool_context, coworker = context(server_context)
          raise ArgumentError, "reason is required" if reason.to_s.strip.blank?
          environment = environment!(coworker)
          eligible = EnvironmentInspection.new(environment).call.rollback_revisions
          target = eligible.find { |revision| revision.id == revision_id.to_i }
          raise ArgumentError, "the requested revision is not an eligible rollback target" unless target
          activation = EnvironmentLifecycle.new(environment).rollback!(actor: "coworker:#{coworker.id}", target_revision: target)
          success(environment, rolled_back: true, activation_id: activation.id)
        end
      end
    end
  end
end
