# One-shot `!` shell command executed against a Coding Mode chat session's
# persistent ChatWorkspace checkout (see app/services/chat_workspace.rb).
# Spawned via ProcessRunner/ChatShellCommandJob; #spawned_process carries the
# actual process lifecycle (pid, kill-request switch) the same way every
# other Syrus-spawned subprocess does.
class ChatShellCommand < ApplicationRecord
  include TracksFinishedAt

  OUTCOMES = %w[ succeeded failed killed error ].freeze

  # Captured combined stdout+stderr (ProcessRunner merges the two streams)
  # is capped so an unbounded `!` command (e.g. `cat` on a huge file) can't
  # grow this row without limit. Kept safely under MySQL's 65,535-byte TEXT
  # limit (with room for TRUNCATION_NOTICE) so a maxed-out capture never
  # trips a "Data too long for column" error under strict SQL mode.
  MAX_OUTPUT_BYTES = 60.kilobytes
  TRUNCATION_NOTICE = "\n… output truncated …\n".freeze

  belongs_to :chat_session
  belongs_to :user
  belongs_to :spawned_process, optional: true

  validates :command, presence: true
  validates :started_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

  # Appends `chunk` to `buffer`, capping total size at MAX_OUTPUT_BYTES and
  # appending a truncation notice once the cap is first exceeded.
  def self.append_capped(buffer, chunk)
    return buffer if buffer.bytesize >= MAX_OUTPUT_BYTES

    combined = buffer + chunk
    return combined if combined.bytesize <= MAX_OUTPUT_BYTES

    combined.safe_byteslice(0, MAX_OUTPUT_BYTES) + TRUNCATION_NOTICE
  end

  def cancellable?
    running? && spawned_process.present? && spawned_process.running?
  end

  # Shared wire shape for this record: the create/cancel endpoint responses
  # (Api::V1::App::ChatShellCommandsController) and the chat payload's
  # `chat_shell_command_in_flight` field (ChatSerialization#chat_payload) both
  # render this exact hash so the composer can rehydrate from either source.
  def as_command_json
    {
      id: id,
      chat_session_id: chat_session_id,
      command: command,
      output: output,
      outcome: outcome,
      exit_status: exit_status,
      started_at: started_at&.iso8601,
      finished_at: finished_at&.iso8601,
      running: running?,
      cancellable: cancellable?
    }
  end
end
