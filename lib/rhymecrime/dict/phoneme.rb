class String
  # treat strings as phonemes

  def vowel?
    self.include?("1") || self.include?("2") || self.include?("0")
  end

  def syllable_boundary?
    self == "."
  end

  def sanitize
    # sanitizes STR so it can be saved in a space-delimited text file
    return self.gsub(" ", "_")
  end

  def desanitize
    # desanitizes STR. The result may contain spaces.
    return self.gsub("_", " ")
  end

end
