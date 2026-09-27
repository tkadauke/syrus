require "mcp"

module OperatorBriefing
  module Tools
    class SubmitDiveReportTool < MCP::Tool
      tool_name "submit_dive_report"

      MAX_TITLE_LENGTH = 120
      MAX_NARRATIVE_LENGTH = 30_000
      MAX_FINDINGS = 12
      MAX_REFERENCES = 20

      description "Creates or revises a durable Operator Briefing topic from a briefing_dive workflow."

      input_schema(
        properties: {
          topic_id: { type: "integer", description: "Existing topic id when list_briefing_topics found a semantic match." },
          title: { type: "string", description: "Topic title, required when creating a new topic." },
          slug: { type: "string", description: "Optional topic slug for a new topic." },
          narrative: { type: "string", description: "Full markdown dive report." },
          findings: { type: "array", items: { type: "string" }, maxItems: MAX_FINDINGS },
          references: { type: "array", items: { type: "object" }, maxItems: MAX_REFERENCES }
        },
        required: %w[narrative]
      )

      class << self
        def call(narrative:, server_context:, topic_id: nil, title: nil, slug: nil, findings: nil, references: nil)
          run = Mcp::Tools.run_from_context(server_context)
          return Mcp::Tools.invalid("submit_dive_report is only available from submit_dive_report") unless run.step&.kind == "submit_dive_report"

          context = run.workflow.artifact("briefing_dive_context") || {}
          briefing = Briefing.find_by(id: context["briefing_id"])
          normalized_narrative = Mcp::Tools.utf8(narrative).strip.truncate(MAX_NARRATIVE_LENGTH)
          return Mcp::Tools.invalid("narrative is required") if normalized_narrative.blank?

          topic = find_or_create_topic!(
            run: run,
            topic_id: topic_id,
            title: title,
            slug: slug,
            briefing: briefing
          )
          revision = append_revision!(topic, briefing, run, normalized_narrative, findings, references)
          link_topic!(topic, briefing, run.workflow, context["selected_text"])

          run.workflow.set_artifact!("briefing_dive_report", {
            "topic_id" => topic.id,
            "topic_revision_id" => revision.id,
            "title" => topic.title,
            "path" => "/briefing/topics/#{topic.id}"
          })
          InterestSignal.record_dive_completed!(user: run.user, briefing: briefing, topic_title: topic.title) if briefing

          Mcp::Tools.success(topic_id: topic.id, topic_revision_id: revision.id, path: "/briefing/topics/#{topic.id}")
        rescue ActiveRecord::RecordInvalid => e
          Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
        rescue ActiveRecord::RecordNotFound
          Mcp::Tools.invalid("briefing topic not found")
        end

        private

        def find_or_create_topic!(run:, topic_id:, title:, slug:, briefing:)
          return BriefingTopic.where(repository: run.job.repository).find(topic_id) if topic_id.present?

          normalized_title = Mcp::Tools.utf8(title).strip.truncate(MAX_TITLE_LENGTH)
          raise ActiveRecord::RecordInvalid.new(BriefingTopic.new.tap { |topic| topic.errors.add(:title, "is required") }) if normalized_title.blank?

          BriefingTopic.create!(
            repository: run.job.repository,
            first_seen_briefing_item: briefing&.items&.first,
            title: normalized_title,
            slug: slug.to_s.presence || normalized_title
          )
        end

        def append_revision!(topic, briefing, run, narrative, findings, references)
          topic.revisions.create!(
            briefing: briefing,
            workflow: run.workflow,
            run: run,
            revision_number: topic.revisions.maximum(:revision_number).to_i + 1,
            generated_at: Time.current,
            narrative: narrative,
            findings: Array(findings).map { |finding| Mcp::Tools.utf8(finding).strip.truncate(300) }.reject(&:blank?).first(MAX_FINDINGS),
            references: Array(references).first(MAX_REFERENCES)
          )
        end

        def link_topic!(topic, briefing, workflow, source_span)
          return unless briefing

          BriefingTopicLink.find_or_create_by!(topic: topic, briefing: briefing, workflow: workflow) do |link|
            link.source_span = source_span.to_s.truncate(180)
          end
        end
      end
    end
  end
end
