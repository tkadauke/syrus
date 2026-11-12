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

  it "does not render bare JSON array literals" do
    controller_files = Dir[
      Rails.root.join("app/controllers/api/**/*_controller.rb"),
      Rails.root.join("plugins/*/app/controllers/api/**/*_controller.rb")
    ]
    offenders = controller_files.select { |file| File.read(file).match?(/render\s+json:\s*\[/) }

    expect(offenders).to be_empty, -> { "Bare JSON array responses: #{offenders.map { |file| file.delete_prefix("#{Rails.root}/") }.join(', ')}" }
  end
end
