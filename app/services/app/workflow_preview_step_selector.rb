module App
  class WorkflowPreviewStepSelector
    LIMIT = 7
    INTERESTING_STATUSES = %w[failed warning].freeze
    OMITTED_FALLBACK_STATUSES = %w[queued cancelled skipped].freeze

    def initialize(steps, active:)
      @steps = steps
      @active = active
    end

    def call
      return [] if steps.empty?

      selected = [ 0 ]
      selected << anchor_index if active
      selected << steps.length - 1 unless active
      add_newest(selected, interesting_indices)
      add_upcoming(selected) if active
      add_newest(selected, reached_indices)

      with_ellipsis(selected.compact.uniq.sort.first(LIMIT))
    end

    private

    attr_reader :steps, :active

    def anchor_index
      steps.index { |step| status(step) == "running" } ||
        steps.each_index.select { |index| status(steps[index]) != "queued" }.last || 0
    end

    def interesting_indices
      steps.each_index.select { |index| INTERESTING_STATUSES.include?(status(steps[index])) }
    end

    def reached_indices
      steps.each_index.reject { |index| OMITTED_FALLBACK_STATUSES.include?(status(steps[index])) }
    end

    def add_newest(selected, candidates)
      candidates.reverse_each do |index|
        break if selected.uniq.length >= LIMIT
        selected << index
      end
    end

    def add_upcoming(selected)
      start = anchor_index + 1
      (start...steps.length).each do |index|
        break if selected.uniq.length >= LIMIT
        selected << index if status(steps[index]) == "queued"
      end
    end

    def status(step)
      step[:display_status] || step["display_status"] || step[:state] || step["state"]
    end

    def with_ellipsis(indices)
      rows = indices.each_with_index.flat_map do |index, position|
        row = preview_row(steps[index])
        next [ row ] if position == indices.length - 1 || indices[position + 1] == index + 1

        [ row, { ellipsis: true } ]
      end
      rows << { ellipsis: true } if indices.last < steps.length - 1
      rows
    end

    def preview_row(step)
      {
        id: step[:id] || step["id"],
        display_name: step[:display_name] || step["display_name"],
        status: status(step)
      }
    end
  end
end
