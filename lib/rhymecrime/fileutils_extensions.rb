require 'fileutils'

module FileUtils
  def self.ensure_directory_exists(dirname)
    unless File.directory?(dirname)
      FileUtils.mkdir_p(dirname)
    end
  end
  
  def self.ensure_file_directory_exists(filename)
    FileUtils.ensure_directory_exists(File.dirname(filename))
  end
end
