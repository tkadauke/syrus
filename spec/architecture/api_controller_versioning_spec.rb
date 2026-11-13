require "rails_helper"

RSpec.describe "API controller versioning" do
  it "covers every application and plugin API controller" do
    Rails.application.eager_load!

    controller_files = Dir[
      Rails.root.join("app/controllers/api/**/*_controller.rb"),
      Rails.root.join("plugins/*/app/controllers/api/**/*_controller.rb")
    ]
    controller_classes = controller_files.map do |file|
      relative = file.sub(%r{\A.*?/app/controllers/}, "").delete_suffix(".rb")
      relative.camelize.constantize
    end

    uncovered = controller_classes.reject { |controller| controller < JsonApiVersioning }
    expect(uncovered).to be_empty, -> { "API controllers without JsonApiVersioning: #{uncovered.map(&:name).sort.join(', ')}" }
  end

  it "does not render obvious bare JSON arrays" do
    controller_files = Dir[
      Rails.root.join("app/controllers/api/**/*_controller.rb"),
      Rails.root.join("plugins/*/app/controllers/api/**/*_controller.rb")
    ]
    bare_array_patterns = [
      /render\s+json:\s*\[/,
      /render\s+json:\s*[^\n{]+\.map\s*\{/
    ]
    offenders = controller_files.select do |file|
      source = File.read(file)
      bare_array_patterns.any? { |pattern| source.match?(pattern) }
    end

    expect(offenders).to be_empty, -> { "Bare JSON array responses: #{offenders.map { |file| file.delete_prefix("#{Rails.root}/") }.join(', ')}" }
  end
end
