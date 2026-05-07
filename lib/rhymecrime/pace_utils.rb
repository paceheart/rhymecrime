#!/usr/bin/env ruby
# useful Ruby utilities

$debug_mode = false

def debug(string)
  if($debug_mode)
    puts string
  end
end

def boolean?(object)
  object == !!object
end

class Array
  # does ARRAY contain any duplicate items?
  def duplicates?
    return self.length != self.uniq.length
  end

  # How many non-nil values does ARRAY contain?
  def non_nil_count
    count = 0
    self.each { |val| count += val ? 1 : 0 }
    return count
  end

  # The sum of all numeric values in ARRAY
  # To be precise, the sum of all values in ARRAY that respond to +
  def sum_numeric
    result = 0
    for value in self
      if value.respond_to?('+')
        result += value
      end
    end
    return result
  end

  # Assuming both ARRAY and OTHER are sorted using the same sort, return their intersection (also sorted)
  def intersection_assuming_sorted(other)
    result = []
    i = 0
    j = 0
    until i >= self.length or j >= other.length do
      case self[i] <=> other[j]
      when -1
        i += 1
      when 1
        j += 1
      else
        result.append(self[i])
        i += 1
        j += 1
      end
    end
    return result
  end
end

class IntegerArray < Array
  def [](index)
    super(index).to_i
  end
end

class ArrayOfIntegerArrays < Array
  def [](index)
    result = super(index)
    if result.nil?
      result = IntegerArray.new
      self[index] = result
    end
    return result
  end
end

class File
  def writeln(str)
    self.write("#{str}\n")
  end
end

class Hash
  # appends VALUE to self[key]
  # Assumes this hash is a hash of arrays (or something that supports append).
  def push(key, value)
    self[key] = self[key].append(value)
  end
  
  # Increments each key in the hash by its corresponding value in other_hash
  # assumes both this hash and other_hash have numeric values
  def hash_increment_all(other_hash)
    for key, num in other_hash
      unless num.nil? # robustify against nils
        self[key] += num
      end
    end
  end

  # Create a new Hash whose default for each key is a new empty array
  def self.new_hash_of_arrays
    Hash.new { |h, k| h[k] = [] }
  end

  # Create a new Hash whose default for each key is a new empty IntegerArray
  def self.new_hash_of_integer_arrays
    Hash.new { |h, k| h[k] = IntegerArray.new }
  end

  # Create a new Hash whose default for each key is a new empty Hash
  def self.new_hash_of_hashes
    Hash.new { |h, k| h[k] = Hash.new }
  end

  # Destructively sort all HASH's values
  def sort_values
    for key, val in self
      val = val.sort!
      self[key] = val
    end
  end
end

class String
  def ensure_trailing(final_char)
    self[-1] == final_char ? self : self + final_char
  end

  def ensure_trailing_newline
    self.ensure_trailing("\n")
  end
  
  def ensure_trailing_slash
    self.ensure_trailing('/')
  end

  # How many alphabetic characters are in this string?
  def count_alpha
    self.count("a-zA-Z")
  end
end

def coin_flip
  rand < 0.5
end

class MessagePackUtils
  def self.load_and_unpack(filename)
    bytes =
      if defined?(BuildIo)
        BuildIo.binread(filename, hint: "MessagePackUtils.load_and_unpack")
      else
        File.binread(filename)
      end
    MessagePack.unpack(bytes)
  end

  def self.pack_and_save(filename, object)
    if defined?(BuildIo)
      BuildIo.binwrite(filename, object.to_msgpack, hint: "MessagePackUtils.pack_and_save")
    else
      File.binwrite(filename, object.to_msgpack)
    end
  end
end
