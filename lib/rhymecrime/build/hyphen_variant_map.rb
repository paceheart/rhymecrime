# frozen_string_literal: true

# Persist hyphen-variant fold map during dict-build. Bucket logic lives in morphology/hyphen.rb
# (also used at runtime when the JSON cache is absent) so the Lambda boot path never loads this file.
require "fileutils"
require "json"
require_relative "../paths"

# build_keys: headwords used to discover fold groups (include rare spellings when pairing hyphen/solid variants).
# exported_keys: final lexicon; a fold is written only when at least one of its spellings remains exported.
def save_hyphen_variant_map!(build_keys, exported_keys: nil)
  exported_keys = build_keys if exported_keys.nil?
  map = build_hyphen_multi_fold_map(build_keys)
  in_export = exported_keys.to_set
  map = map.reject { |_fold, forms| forms.none? { |w| in_export.include?(w) } }
  ensure_generated_dict_dir!
  path =
    if rhymecrime_build_dir
      generated_bootstrap_path(HYPHEN_VARIANT_MAP_FILENAME)
    else
      generated_dict_path(HYPHEN_VARIANT_MAP_FILENAME)
    end
  sorted = {}
  map.keys.sort.each { |k| sorted[k] = map[k].sort }
  FileUtils.mkdir_p(File.dirname(path))
  IoUtils.write(path, "#{JSON.generate(sorted)}\n", encoding: "UTF-8", hint: "save_hyphen_variant_map")
  puts "Wrote #{sorted.size} hyphen-variant folds to #{HYPHEN_VARIANT_MAP_FILENAME}"
  link_runtime_spelling_hyphen_symlinks! if final_mode? && rhymecrime_build_dir
end
