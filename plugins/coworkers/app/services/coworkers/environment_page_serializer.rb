class Coworkers::EnvironmentPageSerializer
  def initialize(environment, coworker:)
    @environment = environment
    @coworker = coworker
  end

  def as_json(*)
    snapshot = Coworkers::EnvironmentInspection.new(environment).call
    Coworkers::EnvironmentInspectionSerializer.new(snapshot).as_json.merge(
      "publication_state" => publication_state(snapshot),
      "verification_state" => snapshot.build_revision&.state,
      "current_base_digest" => snapshot.active_base&.digest,
      "latest_safe_findings" => safe_findings(snapshot.build_revision),
      "revisions" => revisions(snapshot),
      "main_chat_path" => main_chat_path
    )
  end

  private

  attr_reader :environment, :coworker

  def publication_state(snapshot)
    if snapshot.candidate_revision
      "awaiting_publication"
    elsif snapshot.active_revision
      "published"
    else
      "not_published"
    end
  end

  def safe_findings(revision)
    request = revision&.build_request
    request&.evidences&.last&.safe_summary ||
      request&.result&.details.to_h.fetch("evidence", {}).slice(*Coworkers::EnvironmentInspectionSerializer::SAFE_EVIDENCE_KEYS).presence
  end

  def revisions(snapshot)
    rollback_ids = snapshot.rollback_revisions.map(&:id).to_set
    environment.revisions.includes(:runtime_image, :base_release, build_request: :result)
      .reorder(number: :desc).map do |revision|
      request = revision.build_request
      {
        "id" => revision.id,
        "number" => revision.number,
        "state" => revision.state,
        "source_digest" => revision.source_digest,
        "image_digest" => revision.runtime_image&.digest,
        "base_digest" => revision.base_release&.digest,
        "runtime_abi" => revision.runtime_abi,
        "build_state" => request&.state,
        "error_code" => request&.result&.error_code,
        "rollback_eligible" => rollback_ids.include?(revision.id),
        "created_at" => revision.created_at&.iso8601
      }.compact
    end
  end

  def main_chat_path
    chat = coworker.coworker_chats.find(&:main?)&.chat_session
    "/chats/#{chat.id}" if chat
  end
end
