#!/usr/bin/env ruby

require_relative 'json_extensions'
require_relative 'pace_utils'

GNUPLOT_DATA_FILENAME = '/tmp/plot.dat'
GNUPLOT_SCRIPT_FILENAME = '/tmp/plot.plot'
GNUPLOT_SCRIPT = "plot '#{GNUPLOT_DATA_FILENAME}'"

# Treat ARRAY1 as an unordered bag of points. Sort them and display them.
def plot_bag(array1, custom=nil)
  plot_numbers(array1.sort, custom=custom)
end

def plot_numbers(nums, custom=nil)
  i = 1
  datafile = File.open(GNUPLOT_DATA_FILENAME, 'w') { |file|
    for num in nums
      file.writeln "#{i} #{num}"
      i += 1
    end
  }
  exec_gnuplot(custom)
end

def exec_gnuplot(custom=nil)
  write_gnuplot_script(custom)
  `gnuplot #{GNUPLOT_SCRIPT_FILENAME} --persist`
end

def write_gnuplot_script(custom=nil)
  script = ""
  unless custom.nil?
    script += custom.ensure_trailing_newline
  end
  script += GNUPLOT_SCRIPT
  File.write(GNUPLOT_SCRIPT_FILENAME, script)
end
