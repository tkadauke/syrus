require "base64"
require "socket"

module GraderCommandSpans
  class Recorder
    MARKER_PREFIX = "__SYRUS_COMMAND_SPAN__"
    MARKER_START = "\x1e"
    MARKER_END = "\x1f"
    MAX_SPANS_PER_RUN = 50

    attr_reader :plan

    def initialize(run:, step:, workflow:, plan:)
      @run = run
      @step = step
      @workflow = workflow
      @plan = plan
      @line_buffer = +""
      @open_spans = {}
      @span_ids_by_sequence = {}
      @spawned_process_id = nil
      create_fallback_span! unless plan.instrumentable?
    end

    def shell_prelude
      return "" unless plan.instrumentable?

      <<~BASH
        __syrus_span() {
          local __syrus_seq="$1"
          local __syrus_name="$2"
          local __syrus_command="$3"
          local __syrus_started_ms
          local __syrus_exit
          __syrus_started_ms="$(date +%s%3N)"
          printf '\\036%s\tstart\t%s\t%s\t%s\t%s\\037' '#{MARKER_PREFIX}' "$__syrus_seq" "$__syrus_started_ms" "$(printf '%s' "$__syrus_name" | base64 | tr -d '\\n')" "$(printf '%s' "$__syrus_command" | base64 | tr -d '\\n')"
          eval "$__syrus_command"
          __syrus_exit="$?"
          printf '\\036%s\tfinish\t%s\t%s\t%s\\037' '#{MARKER_PREFIX}' "$__syrus_seq" "$(date +%s%3N)" "$__syrus_exit"
          return "$__syrus_exit"
        }
      BASH
    end

    def wrap(command)
      return command unless plan.instrumentable?

      "#{shell_prelude}\n#{command}"
    end

    def spawned_process=(process)
      @spawned_process_id = process&.id
      CommandSpan.where(run_id: @run.id, spawned_process_id: nil).update_all(spawned_process_id: @spawned_process_id) if @spawned_process_id
    end

    def consume(chunk)
      visible = +""
      @line_buffer << chunk

      loop do
        marker_start = @line_buffer.index(MARKER_START)
        unless marker_start
          visible << @line_buffer
          @line_buffer = +""
          break
        end

        visible << @line_buffer.slice!(0, marker_start)
        marker_end = @line_buffer.index(MARKER_END)
        break unless marker_end

        marker = @line_buffer.slice!(0..marker_end)
        record_marker(marker.byteslice(1, marker.bytesize - 2))
      end

      visible
    end

    def flush_visible
      return "" if @line_buffer.empty?

      line = @line_buffer
      @line_buffer = +""
      consume(line)
    end

    def finalize!(exit_code:, timed_out:, stopped: false, operator_killed: false)
      if plan.instrumentable?
        @open_spans.each_value do |span|
          finish_span!(span, finished_at: Time.current, exit_status: nil, outcome: final_outcome(exit_code, timed_out, stopped, operator_killed))
        end
      else
        span = CommandSpan.find_by(id: @span_ids_by_sequence[1])
        finish_span!(span, finished_at: Time.current, exit_status: exit_code, outcome: final_outcome(exit_code, timed_out, stopped, operator_killed)) if span
      end
      @open_spans.clear
    end

    private

    def create_fallback_span!
      fragment = plan.fragments.first
      span = create_span!(
        sequence: 1,
        name: fragment.name,
        command_excerpt: fragment.command,
        started_at: Time.current,
        metadata: {
          "instrumentation" => "fallback",
          "fallback_reason" => plan.fallback_reason
        }.compact
      )
      @span_ids_by_sequence[1] = span.id
    end

    def record_marker(marker)
      parts = marker.to_s.split("\t")
      return unless parts.first == MARKER_PREFIX

      case parts[1]
      when "start"
        start_span_from_marker(parts)
      when "finish"
        finish_span_from_marker(parts)
      end
    rescue StandardError => e
      Rails.logger.warn("[GraderCommandSpans::Recorder] ignored malformed span marker for Run ##{@run.id}: #{e.class}: #{e.message}")
    end

    def start_span_from_marker(parts)
      sequence = Integer(parts.fetch(2))
      return if sequence > MAX_SPANS_PER_RUN

      span = create_span!(
        sequence: sequence,
        name: decode64(parts.fetch(4)).presence || "command ##{sequence}",
        command_excerpt: decode64(parts.fetch(5)).squish.safe_byteslice(0, Plan::MAX_COMMAND_EXCERPT),
        started_at: time_from_ms(parts.fetch(3)),
        metadata: { "instrumentation" => "bash_marker" }
      )
      @span_ids_by_sequence[sequence] = span.id
      @open_spans[sequence] = span
    end

    def finish_span_from_marker(parts)
      sequence = Integer(parts.fetch(2))
      span = @open_spans.delete(sequence) || CommandSpan.find_by(id: @span_ids_by_sequence[sequence])
      return unless span

      exit_status = Integer(parts.fetch(4))
      finish_span!(
        span,
        finished_at: time_from_ms(parts.fetch(3)),
        exit_status: exit_status,
        outcome: exit_status.zero? ? "succeeded" : "failed"
      )
    end

    def create_span!(sequence:, name:, command_excerpt:, started_at:, metadata:)
      CommandSpan.create!(
        job: @run.job,
        workflow: @workflow,
        step: @step,
        run: @run,
        spawned_process_id: @spawned_process_id,
        sequence: sequence,
        name: name.to_s.safe_byteslice(0, 128),
        command_excerpt: command_excerpt.to_s.safe_byteslice(0, Plan::MAX_COMMAND_EXCERPT),
        started_at: started_at,
        hostname: Socket.gethostname,
        metadata: metadata
      )
    end

    def finish_span!(span, finished_at:, exit_status:, outcome:)
      return if span.finished_at.present?

      duration_ms = ((finished_at - span.started_at) * 1000).round
      span.update!(
        finished_at: finished_at,
        duration_ms: [ duration_ms, 0 ].max,
        exit_status: exit_status,
        outcome: outcome
      )
    end

    def final_outcome(exit_code, timed_out, stopped, operator_killed)
      return "operator_killed" if operator_killed
      return "timed_out" if timed_out
      return "stopped" if stopped
      return "succeeded" if exit_code.to_i.zero?
      return "failed" unless exit_code.nil?

      "incomplete"
    end

    def time_from_ms(value)
      Time.zone.at(Integer(value).to_f / 1000)
    end

    def decode64(value)
      Base64.decode64(value.to_s)
    end
  end
end
