class RuntimeControlLease < ApplicationRecord
  STATES = %w[ active released cancelled expired ].freeze
  OWNERS = %w[ none user agent ].freeze
  MODES = %w[ observe_only input build lifecycle ].freeze

  # observe_only never takes a lease (the operator can always observe); input
  # is serialized on its own so agent/user pointer-keyboard-touch events never
  # interleave, while build and lifecycle operations share a second, separate
  # serialization group per DOC-17 ("build/reload and lifecycle operations
  # should be serialized separately from input").
  SERIALIZATION_GROUPS = {
    "input" => "input",
    "build" => "build_lifecycle",
    "lifecycle" => "build_lifecycle"
  }.freeze

  MIN_DURATION = 15.seconds
  MAX_DURATION = 60.seconds
  DEFAULT_DURATION = 30.seconds

  # JobLog is the app's existing durable, queryable audit-event convention —
  # used across Job/Workflow/Run/Step lifecycle transitions — so lease
  # lifecycle and input events are appended there instead of inventing a
  # parallel log. Only sessions attached to a Run (e.g. a visual-review or
  # other workflow-driven session) have a JobLog to write into; chat-only
  # Coding Mode sessions rely on the lease rows themselves (append-only,
  # nothing is ever deleted or overwritten past its terminal state) plus the
  # live ActionCable broadcast below for real-time visibility.
  AUDIT_KIND = "runtime_control_lease"

  belongs_to :runtime_session

  validates :owner, inclusion: { in: OWNERS }
  validates :mode, inclusion: { in: MODES }
  validates :state, inclusion: { in: STATES }

  after_create_commit :handle_acquired

  scope :in_state, ->(state) { where(state: state) }
  scope :active, -> { where(state: "active").where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :held_by, ->(owner) { where(owner: owner) }
  scope :for_mode, ->(mode) { where(mode: mode) }

  class Conflict < StandardError; end
  class NotCancellable < StandardError; end

  # Acquires a new lease for a runtime session, raising Conflict when another
  # active lease already holds the same serialization group (input, or
  # build/lifecycle). observe_only never requires a lease at all.
  def self.acquire!(runtime_session:, owner:, mode:, owner_ref: nil, reason: nil, duration_seconds: nil, cancellable: true)
    raise ArgumentError, "observe_only does not require a lease" if mode == "observe_only"

    group = SERIALIZATION_GROUPS.fetch(mode) { raise ArgumentError, "unknown mode #{mode.inspect}" }
    group_modes = SERIALIZATION_GROUPS.select { |_, g| g == group }.keys
    duration = (duration_seconds || DEFAULT_DURATION).to_i.clamp(MIN_DURATION.to_i, MAX_DURATION.to_i)

    transaction do
      conflict = runtime_session.runtime_control_leases.active.where(mode: group_modes).lock.first
      raise Conflict, "runtime session #{runtime_session.id} already has an active #{group} lease" if conflict

      create!(
        runtime_session: runtime_session,
        owner: owner,
        owner_ref: owner_ref,
        mode: mode,
        reason: reason,
        state: "active",
        acquired_at: Time.current,
        expires_at: duration.seconds.from_now,
        cancellable: cancellable
      )
    end
  end

  # Immediately revokes the runtime session's active agent lease(s), bypassing
  # the `cancellable` cooperation flag entirely — the operator's abort path
  # must always win, per DOC-17 ("Syrus should revoke the agent lease
  # immediately and reject subsequent input events until a new lease is
  # granted"). No-op (returns an empty array) when the agent holds no active
  # lease.
  def self.abort_agent_control!(runtime_session:, reason: nil)
    runtime_session.runtime_control_leases.active.held_by("agent").map { |lease| lease.abort!(reason: reason) }
  end

  # Audits an input event rejected for lack of an active lease — there is no
  # lease row to attach it to, so this writes directly against the session.
  def self.audit_input_rejected!(runtime_session:, event:)
    audit!(runtime_session: runtime_session, action: "input_rejected", details: event)
  end

  def active?
    state == "active" && !expired_by_time?
  end

  def expired_by_time?
    expires_at.present? && expires_at <= Time.current
  end

  def release!
    update!(state: "released", released_at: Time.current)
    finish(event: "release")
    self
  end

  # Cooperative cancellation — refuses when the lease was acquired as
  # non-cancellable. Use `abort!` for the operator emergency-stop path, which
  # must succeed regardless.
  def cancel!(reason: nil)
    raise NotCancellable, "lease #{id} is not cancellable" unless cancellable?

    update!(state: "cancelled", cancel_reason: reason, released_at: Time.current)
    finish(event: "cancel")
    self
  end

  # Operator abort — always succeeds, independent of `cancellable`, and
  # independent of any cooperation from the agent.
  def abort!(reason: nil)
    update!(state: "cancelled", cancel_reason: reason || "aborted by operator", released_at: Time.current)
    finish(event: "abort")
    self
  end

  def expire!
    return self unless state == "active"

    update!(state: "expired", released_at: Time.current)
    finish(event: "expire")
    self
  end

  def record_input!(event)
    self.class.send(:audit!, runtime_session: runtime_session, action: "input", lease: self, details: event)
    notify_channel(event: "input", details: event)
    self
  end

  private_class_method def self.audit!(runtime_session:, action:, lease: nil, details: nil)
    run = runtime_session.run
    return unless run

    JobLog.append!(run: run, kind: AUDIT_KIND, chunk: audit_line(runtime_session, action, lease, details))
  end

  private_class_method def self.audit_line(runtime_session, action, lease, details)
    parts = [ "runtime_control_lease", "session=#{runtime_session.id}", "action=#{action}" ]
    if lease
      parts << "lease=#{lease.id}"
      parts << "owner=#{lease.owner}"
      parts << "mode=#{lease.mode}"
      parts << "reason=#{lease.reason}" if lease.reason.present?
    end
    parts << "details=#{details.to_json}" if details.present?
    parts.join(" ")
  end

  private

  def handle_acquired
    self.class.send(:audit!, runtime_session: runtime_session, action: "acquire", lease: self)
    notify_channel(event: "acquire")
  end

  def finish(event:)
    self.class.send(:audit!, runtime_session: runtime_session, action: event, lease: self)
    notify_channel(event: event)
  end

  def notify_channel(event:, details: nil)
    ActionCable.server.broadcast(
      "runtime_session_#{runtime_session_id}_control",
      { type: event, lease_id: id, owner: owner, owner_ref: owner_ref, mode: mode, reason: reason, details: details }
    )
  end
end
