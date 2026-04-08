#!/usr/bin/env ruby

#
# front end for RhymeCrime
#

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rhymecrime/frontend"
compute_and_print_html
