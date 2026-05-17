module Filters
  Subject = Data.define(:name, :model, :chips) do
    def initialize(name:, model:, chips:)
      super(name: name.to_sym, model: model, chips: chips.stringify_keys.freeze)
    end

    def chip_class(field)
      class_name = chips[field.to_s] or raise UnknownFilterField.new(field)
      class_name.constantize
    end

    def fields
      chips.keys
    end
  end
end
