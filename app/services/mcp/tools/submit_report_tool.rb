require "mcp"

module Mcp::Tools
  # Stores the agent-authored investigation report on the current Workflow.
  # The Syrus harness invokes this tool from the submit_report step of
  # `investigation` Workflows -- the narrative-producing step the chain
  # exists to reach instead of dead-ending on a blank diff. There is no PR
  # for this narrative to ride along with, so it lands directly on
  # Workflow#artifacts under "investigation_report". `references` lets the
  # narrative point at evidence already captured this run via submit_artifact
  # / submit_visual_artifact -- it stores pointers (an artifact `type` plus an
  # optional caption), not copies, so a future report renderer resolves them
  # against Workflow#artifacts["typed_artifacts"] at render time.
  class SubmitReportTool < MCP::Tool
    tool_name "submit_report"

    MAX_TITLE_LENGTH = 120
    MAX_NARRATIVE_LENGTH = 20_000
    MAX_FINDINGS = 10
    MAX_FINDING_LENGTH = 240
    MAX_REFERENCES = 20
    MAX_REFERENCE_CAPTION_LENGTH = 200

    description <<~DESC
      Stores a narrative investigation report on the current Workflow. The
      Syrus harness invokes this tool from the submit_report step of an
      investigation Job -- there is no PR, so this report is the Job's
      deliverable. title is a short label; narrative is the full
      markdown write-up (your answer plus the evidence for it); findings
      is an optional list of concise, standalone call-outs; references is
      an optional ordered list pointing at artifacts/screenshots already
      submitted this run via submit_artifact/submit_visual_artifact.
    DESC

    input_schema(
      properties: {
        title: {
          type: "string",
          description: "Short title for the report, under #{MAX_TITLE_LENGTH} characters."
        },
        narrative: {
          type: "string",
          description: "Full report body in markdown: your answer, the evidence for it, and any caveats."
        },
        findings: {
          type: "array",
          items: { type: "string" },
          maxItems: MAX_FINDINGS,
          description: "Optional list of at most #{MAX_FINDINGS} short, standalone findings."
        },
        references: {
          type: "array",
          items: {
            type: "object",
            properties: {
              type: {
                type: "string",
                description: "The exact artifact type you used with submit_artifact/submit_visual_artifact this run. For submit_visual_artifact, use the resolved type echoed back in that tool's response, since it may differ from the type you requested."
              },
              caption: {
                type: "string",
                description: "Optional short caption for this reference, under #{MAX_REFERENCE_CAPTION_LENGTH} characters."
              }
            },
            required: %w[type]
          },
          maxItems: MAX_REFERENCES,
          description: "Optional ordered list of at most #{MAX_REFERENCES} references to artifacts/screenshots already submitted this run via submit_artifact or submit_visual_artifact. Each `type` must match an artifact you already submitted."
        }
      },
      required: %w[title narrative]
    )

    class << self
      def call(title:, narrative:, findings: nil, references: nil, server_context:)
        run = Mcp::Tools.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return Mcp::Tools.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_report)

        normalized_title = Mcp::Tools.utf8(title).strip.truncate(MAX_TITLE_LENGTH)
        normalized_narrative = Mcp::Tools.utf8(narrative).strip.truncate(MAX_NARRATIVE_LENGTH)
        normalized_findings = normalize_findings(findings)
        normalized_references, reference_error = normalize_references(references, run.workflow)

        return Mcp::Tools.invalid("title is required")     if normalized_title.empty?
        return Mcp::Tools.invalid("narrative is required")  if normalized_narrative.empty?
        return Mcp::Tools.invalid(reference_error) if reference_error

        run.workflow.set_artifact!("investigation_report", {
          title: normalized_title,
          narrative: normalized_narrative,
          findings: normalized_findings,
          references: normalized_references
        })
        Mcp::Tools.write_log(run, "[mcp] submit_report received: #{normalized_title.inspect}")

        MCP::Tool::Response.new([ { type: "text", text: "Saved." } ])
      rescue StandardError => e
        Rails.logger.error("[Mcp::Tools::SubmitReportTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end

      private

      def normalize_findings(findings)
        Array(findings).map { |finding| Mcp::Tools.utf8(finding).strip.truncate(MAX_FINDING_LENGTH) }.reject(&:empty?).first(MAX_FINDINGS)
      end

      # Returns [normalized_references, error_message]. A reference whose
      # `type` doesn't match anything already submitted this run via
      # submit_artifact/submit_visual_artifact is a real correctness bug in
      # the agent's tool sequence (a dangling pointer the report renderer
      # could never resolve), so this fails loudly instead of silently
      # dropping the reference the way normalize_findings drops blanks.
      def normalize_references(references, workflow)
        return [ [], nil ] if references.blank?

        known_types = known_artifact_types(workflow)

        normalized = Array(references).first(MAX_REFERENCES).map do |reference|
          reference = reference.is_a?(Hash) ? reference.stringify_keys : {}
          ref_type = Mcp::Tools.utf8(reference["type"]).strip
          caption = Mcp::Tools.utf8(reference["caption"]).strip.truncate(MAX_REFERENCE_CAPTION_LENGTH)

          return [ nil, "references[].type is required" ] if ref_type.empty?
          unless known_types.include?(ref_type)
            return [ nil, "references type #{ref_type.inspect} does not match any artifact submitted this run via submit_artifact/submit_visual_artifact" ]
          end

          { "type" => ref_type, "caption" => caption }.compact_blank
        end

        [ normalized, nil ]
      end

      def known_artifact_types(workflow)
        Array(workflow.artifact("typed_artifacts")).each_with_object(Set.new) do |entry, set|
          next unless entry.is_a?(Hash)

          set << entry["type"] if entry["type"].present?
          set << entry["original_type"] if entry["original_type"].present?
        end
      end
    end
  end
end
