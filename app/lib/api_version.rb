module ApiVersion
  CURRENT = 1

  def self.envelope(payload)
    { v: CURRENT }.merge(payload.except(:v, "v"))
  end
end
