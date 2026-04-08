require 'json'

module JSON
  def self.load(filename)
    self.parse(File.read(filename, encoding: 'UTF-8'))
  end
  
  def self.load!(filename)
    self.parse!(File.read(filename, encoding: 'UTF-8'))
  end

  def self.save(filename, obj)
    File.write(filename, JSON.generate(obj))
  end
end
