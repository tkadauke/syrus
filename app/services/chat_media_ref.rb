module ChatMediaRef
  FORMAT = /\A(snapshot|chat_image|preview_panel_version):\d+\z/

  def self.valid?(ref)
    FORMAT.match?(ref.to_s)
  end

  def self.split(ref)
    kind, id_str = ref.to_s.split(":", 2)
    [ kind, id_str.to_i ]
  end
end
