module Coworkers
  class TurnAvailabilityGate
    REASON = "coworker_turn_in_flight"
    RETRY_DELAY = 1.minute

    def self.call(work_unit, step: nil, **)
      return WorkUnits::GateResult.pass unless step&.kind == "coworker_run"

      job = work_unit.workflow&.job || work_unit.member_jobs.first
      return WorkUnits::GateResult.pass unless job
      coworker = Coworkers::Coworker.find_by(id: job.origin_id) if job.origin == "coworkers"
      main_chat = coworker&.coworker_chats&.find_by(role: "main")&.chat_session
      return WorkUnits::GateResult.pass unless main_chat&.turn_in_flight?

      WorkUnits::GateResult.block(
        reason: REASON,
        retry_at: RETRY_DELAY.from_now,
        details: { "coworker_id" => coworker.id, "chat_session_id" => main_chat.id }
      )
    end
  end
end
