module Filters
  module Chips
    # Schema-only chip metadata. Filters::Compiler handles this macro before
    # ordinary subject chip lookup so every SmartFolder subject can use it.
    class SmartFolderPreset < Base
      filter_name Filters::SmartFolderResolution::PRESET_FIELD
      label "Preset"
      bucket :preset
      operators :is

      def apply
        raise NotImplementedError, "SmartFolder presets are expanded by Filters::Compiler"
      end
    end
  end
end
