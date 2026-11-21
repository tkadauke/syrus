require "rails_helper"

# These associations carry a default `order` scope. `.order(...)` on them
# *appends* to it, so `job.workflows.order(created_at: :desc).first` sorts
# by `created_at ASC, ..., created_at DESC` and returns the *oldest* row.
# Code that wants another order must use `reorder`
# (formal/SyrusModel/AssociationOrder.lean). This spec fails on any
# descending `order` chained onto one of them, including across lines.
RSpec.describe "default-ordered associations" do
  def associations
    Rails.application.eager_load!
    ApplicationRecord.descendants.flat_map do |model|
      model.reflect_on_all_associations(:has_many).filter_map do |reflection|
        reflection.name.to_s if reflection.scope && default_ordered?(reflection)
      end
    end.uniq
  end

  def default_ordered?(reflection)
    relation = reflection.klass.unscoped.instance_exec(nil, &reflection.scope)
    relation.respond_to?(:order_values) && relation.order_values.any?
  rescue StandardError
    false
  end

  # Ruby statements with their leading-dot continuation lines joined.
  def statements(path)
    lines = File.readlines(path)
    lines.each_with_index.each_with_object([]) do |(line, index), out|
      if line.lstrip.start_with?(".") && out.any?
        out.last[1] << " " << line.strip
      else
        out << [ index + 1, line.strip.dup ]
      end
    end
  end

  it "never sorts a default-ordered association descending with order instead of reorder" do
    names = associations
    expect(names).to include("workflows", "runs", "steps", "job_logs")
    pattern = /\.(?:#{names.map { |name| Regexp.escape(name) }.join("|")})\b(?:(?!\.reorder\().)*?\.order\([^)]*(?:desc|DESC)/

    offenders = Dir[Rails.root.join("{app,lib,plugins}/**/*.rb")].reject { |path| path.include?("/spec/") }.flat_map do |path|
      statements(path).filter_map do |line_number, text|
        next if text.start_with?("#")
        next unless text.match?(pattern)

        "#{Pathname.new(path).relative_path_from(Rails.root)}:#{line_number}: #{text.first(160)}"
      end
    end

    expect(offenders).to be_empty, "use reorder (order appends to the association's default order):\n#{offenders.join("\n")}"
  end
end
