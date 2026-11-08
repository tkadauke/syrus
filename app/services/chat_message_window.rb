# How many messages the chat stream loads at once.
#
# The surface is filled by rendered rows, not by raw messages, and the two are
# not proportional: the stream joins a run of consecutive tool calls into one
# collapsed card. A window measured in messages therefore has no predictable
# height -- a tool-heavy stretch of thirty messages can render as a single row,
# which leaves the reader with a mostly empty surface and nothing to scroll,
# and forces the client to chain many round trips to catch up.
#
# So size the window by the rows it will produce. A run of consecutive tool
# messages counts once here, which is the fewest rows the stream can draw for
# it -- the client may split a run into several cards when the tools differ,
# never more than one per call -- so the estimate errs toward loading more
# rather than too few, which is the side that keeps the surface scrollable.
#
# Rows are cheap to draw and not cheap to ship, so three ceilings bound one
# window: a row target, a message count, and a byte budget. The budget is a
# ceiling rather than a target -- the message that would cross it ends the
# window instead of joining it. A tool result can carry a megabyte of
# transcript and the payload ships it whole, so where results run that large
# every row costs about a megabyte and a bigger budget buys bytes and no rows
# at all. Such a chat cannot be given a full surface from this end; it needs
# those results to stop being shipped whole. Everywhere else the budget is out
# of reach and the row target decides the window -- and it is a bound where
# there was none, since a window used to be thirty messages of unexamined size.
class ChatMessageWindow
  TOOL_ROLES = %w[ tool_use tool_result ].freeze
  ROW_TARGET = 40
  MAX_MESSAGES = 240
  MAX_BYTES = 1_500_000
  CHUNK_SIZE = 60

  def initialize(scope, row_target: ROW_TARGET, max_messages: MAX_MESSAGES, max_bytes: MAX_BYTES, chunk_size: CHUNK_SIZE)
    @scope = scope
    @row_target = row_target
    @max_messages = max_messages
    @max_bytes = max_bytes
    @chunk_size = chunk_size
  end

  # Returns the window oldest-first, plus whether anything older remains.
  def call(before: nil)
    collected = []
    cursor = before
    bytes = 0
    rows = 0
    open_tool_run = false
    done = false

    until done
      chunk = chunk_before(cursor)
      break if chunk.empty?

      chunk.each do |message|
        size = message_bytes(message)
        # A ceiling, not a target: the message that would cross it closes the
        # window instead of joining it. The first message is exempt, so a
        # window always returns something.
        if collected.any? && bytes + size > max_bytes
          done = true
          break
        end

        collected << message
        bytes += size
        if TOOL_ROLES.include?(message.role)
          rows += 1 unless open_tool_run
          open_tool_run = true
        else
          rows += 1
          open_tool_run = false
        end

        if rows >= row_target || collected.size >= max_messages
          done = true
          break
        end
      end

      cursor = collected.last.id
    end

    [ collected.reverse, more_before?(collected.last&.id) ]
  end

  private

  attr_reader :scope, :row_target, :max_messages, :max_bytes, :chunk_size

  def chunk_before(cursor)
    relation = scope.order(id: :desc).limit(chunk_size)
    relation = relation.where("id < ?", cursor) if cursor
    relation.to_a
  end

  def more_before?(oldest_id)
    return false if oldest_id.nil?

    scope.where("id < ?", oldest_id).exists?
  end

  # A proxy for what the message costs on the wire. The rendered payload adds
  # its own envelope, but a message's content is what makes a page large or
  # small by orders of magnitude, so it is what the budget has to track.
  def message_bytes(message)
    message.content.to_json.bytesize
  end
end
