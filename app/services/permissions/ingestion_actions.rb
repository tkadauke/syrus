require "digest"

module Permissions
  # Stable capability contracts for chat tools that bring outside content into
  # a conversation, materialize stored attachments, read confidential records,
  # or bind a conversation to a repository:
  #
  # - +syrus.ingestion@v1+: pulling external pull-request and issue content
  #   into Syrus (+network_read+). Ingesting a pull request also creates a Job.
  # - +syrus.attachments@v1+: materializing chat media and reading stored
  #   artifacts.
  # - +syrus.confidential_reads@v1+: transcripts, job diffs, and other chats'
  #   messages, which can contain secrets or private source.
  # - +syrus.resource_bindings@v1+: attaching or detaching a repository, which
  #   widens or narrows what the conversation can see.
  #
  # The mapping only supplies classification, default policy, redaction, and
  # fingerprint data. Visibility filtering and record lookup stay in the tools,
  # which keep answering an unknown and an invisible record identically.
  #
  # Redaction never stores free text. Query, body, and content arguments are
  # replaced by a short digest, identifiers are kept, and every redacted
  # argument set carries the provenance of the content the operation touches
  # (+external_untrusted+ for outside content, +syrus_internal+ otherwise) so
  # an approval card can say where the data came from. Provenance is not part
  # of the fingerprint, so it can never make two identical calls differ.
  class IngestionActions
    Operation = Data.define(:capability, :name, :effects, :risk, :default, :maximum_autonomy, :durations, :provenance, :scope)

    INGESTION = "syrus.ingestion@v1".freeze
    ATTACHMENTS = "syrus.attachments@v1".freeze
    CONFIDENTIAL_READS = "syrus.confidential_reads@v1".freeze
    RESOURCE_BINDINGS = "syrus.resource_bindings@v1".freeze

    SESSION = %i[invocation chat_session].freeze
    ANY_DURATION = CapabilityDescriptor::AUTHORITY_DURATIONS

    EXTERNAL = :external_untrusted
    INTERNAL = :syrus_internal

    REDACTED_KEYS = %w[query body content text prompt].freeze

    OPERATIONS = {
      "ingest_pull_request" => Operation.new(INGESTION, "pull_request", %i[network_read internal_write], :medium, :ask, :chat_session, SESSION, EXTERNAL, :none),
      "read_pr" => Operation.new(INGESTION, "read_pull_request", %i[network_read], :low, :allow, :permanent, ANY_DURATION, EXTERNAL, :none),
      "list_open_issues" => Operation.new(INGESTION, "list_open_issues", %i[network_read], :low, :allow, :permanent, ANY_DURATION, EXTERNAL, :none),
      "list_open_prs" => Operation.new(INGESTION, "list_open_prs", %i[network_read], :low, :allow, :permanent, ANY_DURATION, EXTERNAL, :none),
      "list_chat_media" => Operation.new(ATTACHMENTS, "materialize_chat_media", %i[internal_write], :low, :allow, :permanent, ANY_DURATION, INTERNAL, :none),
      "read_artifact" => Operation.new(ATTACHMENTS, "read_artifact", %i[confidential_read], :medium, :ask, :chat_session, SESSION, INTERNAL, :none),
      "read_run_transcript" => Operation.new(CONFIDENTIAL_READS, "read_run_transcript", %i[confidential_read], :medium, :ask, :chat_session, SESSION, INTERNAL, :none),
      "get_job_diff" => Operation.new(CONFIDENTIAL_READS, "read_job_diff", %i[confidential_read], :medium, :ask, :chat_session, SESSION, INTERNAL, :none),
      # Allowed, like its sibling search_chats: the tool resolves the target
      # through current_user.accessible_chat_sessions, so the confidentiality
      # boundary is enforced before the read happens and the prompt confirmed
      # an access check that had already passed. Asking here meant an agent
      # could search every chat without interruption but not open one.
      "read_chat_messages" => Operation.new(CONFIDENTIAL_READS, "read_chat_messages", %i[confidential_read], :medium, :allow, :chat_session, SESSION, INTERNAL, :none),
      "search_chats" => Operation.new(CONFIDENTIAL_READS, "search_chats", %i[confidential_read], :low, :allow, :permanent, ANY_DURATION, INTERNAL, :none),
      # Allowed, like detach_repository below and like the coworker surface,
      # which has always allowed it. Binding a repository the owner can
      # already see to their own chat is how work starts; gating it stopped
      # the agent before it could read anything at all.
      "attach_repository" => Operation.new(RESOURCE_BINDINGS, "attach_repository", %i[internal_write], :medium, :allow, :chat_session, SESSION, INTERNAL, :repository),
      "detach_repository" => Operation.new(RESOURCE_BINDINGS, "detach_repository", %i[internal_write], :low, :allow, :permanent, ANY_DURATION, INTERNAL, :none)
    }.freeze

    class << self
      def tool_names = OPERATIONS.keys

      def covers?(tool_name) = OPERATIONS.key?(tool_name.to_s)

      def descriptor_for(tool_name, required_roles: AgentRole::CHAT_ROLES)
        operation = OPERATIONS.fetch(tool_name.to_s)
        identifier = "#{operation.capability.delete_suffix('@v1')}/#{operation.name}@v1"
        roles = Array(required_roles)

        CapabilityDescriptor.new(
          capability: operation.capability,
          operation: identifier,
          presentation: CapabilityPresentation.for(capability: operation.capability, operation: identifier),
          effects: operation.effects,
          risk: operation.risk,
          requestable_roles: roles,
          defaults: roles.index_with { operation.default },
          maximum_autonomy: operation.maximum_autonomy,
          authority_durations: operation.durations,
          resource_scope: resource_scope(operation.scope),
          classifier: ->(_arguments) { { operation: identifier, effects: operation.effects, risk: operation.risk, confidence: :certain } },
          fingerprint_normalizer: method(:normalize_arguments),
          redactor: ->(arguments) { redact_arguments(arguments, operation.provenance) }
        )
      end

      # Exact arguments, key-sorted, with omitted optionals dropped so an
      # omitted argument and an explicit nil fingerprint identically.
      def normalize_arguments(arguments)
        arguments.to_h.transform_keys(&:to_s).reject { |_key, value| value.nil? }.sort_by { |key, _| key }.to_h
      end

      # Identifiers stay readable; free text becomes a short digest so
      # approval history never retains what was searched for or supplied.
      def redact_arguments(arguments, provenance)
        redacted = normalize_arguments(arguments).to_h do |key, value|
          [ key, REDACTED_KEYS.include?(key) ? "[redacted:#{Digest::SHA256.hexdigest(value.to_s)[0, 12]}]" : value ]
        end
        redacted.merge("provenance" => provenance.to_s)
      end

      def resource_scope(kind)
        return { type: :none } unless kind == :repository

        # The scope is the repository slug alone: no lookup, so a rule's label
        # and comparison never reveal whether a repository exists or is visible.
        ResourceScopeSchema.new(
          type: :repository,
          normalize: lambda { |scope, context:|
            slug = scope.to_h.transform_keys(&:to_s)["slug"].to_s.strip.downcase
            slug.empty? ? {} : { "slug" => slug }
          },
          label: lambda { |scope, context:| scope.empty? ? "Any repository" : "Repository #{scope['slug']}" },
          compare: lambda { |invocation, rule, context:|
            if rule.empty? then invocation.empty? ? :equal : :narrower
            elsif invocation == rule then :equal
            else :disjoint
            end
          }
        )
      end
    end
  end
end
