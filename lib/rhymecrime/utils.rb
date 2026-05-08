# frozen_string_literal: true

# Runtime dictionary helpers (paths, curated lists, spelling, corpus readers, lexicon I/O).
# Load order is fixed — each chunk may depend on earlier ones.
#
# Must not transitively require build/build_io.rb (validated I/O gate + audit); see
# spec/load_path_contract_spec.rb. Neutral reads use build_io_utils.
#
# Dict-build and other offline tools load rhymecrime/build/build_utils, which pulls this
# barrel in first.

require_relative "paths"
require_relative "curated_rarity"
require_relative "spelling"
require_relative "hyphen"
require_relative "prefix_clusters"
require_relative "lexicon_io"
