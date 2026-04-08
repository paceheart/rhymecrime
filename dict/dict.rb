#!/usr/bin/env ruby
# encoding: utf-8
#
# CLI entry: rebuild RhymeCrime caches under ../generated/.
# Run from this directory (dict/) so relative paths resolve:
#   ruby dict.rb
#
# Implementation lives in dict_lib.rb.

require_relative 'dict_lib'

rebuild_rhymecrime_dictionaries
