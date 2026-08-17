module Skills
  # Uniform metadata for a resolved skill, regardless of whether it came
  # from a repo-local SKILL.md or a built-in Skills:: PORO class. Later
  # Jobs in this Epic render `parameters` as a launch form and validate
  # ScheduledTask/slash-command args against it via
  # Skills::ParameterSchema.validate!. `instructions` is the raw
  # instruction text (unrendered — parameter substitution is a later
  # Job's concern).
  Definition = Data.define(:name, :description, :parameters, :instructions)
end
