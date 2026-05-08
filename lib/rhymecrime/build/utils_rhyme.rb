# frozen_string_literal: true

# RhymeCrime dictionary utilities, split across sibling .rb files in build/ for maintainability.
# Load order is fixed — each chunk may depend on earlier ones.
#
# Runtime vs build (see rhymecrime/crime + spec/load_path_contract_spec.rb):
#   * crime.rb / related.rb load this barrel; they must not transitively require
#     build_io.rb (validated I/O gate + audit). Neutral reads use build_io_utils.
#   * dict-build loads dict.rb under build/, which pulls frequency/rime/etc.;
#     those files explicitly require build_io where validation is desired.
#
# Further split for a hard runtime/build boundary: move corpus mirror *writers*
# (save_conceptnet_edges!, save_numberbatch_vectors!, build_usf_associations!) into
# a module required only from dict.rb / bin/setup-corpora, and keep streaming *readers*
# in chunks loaded by crime if signals lazy-load needs them.

require_relative "paths"
require_relative "curated_rarity"
require_relative "spelling"
require_relative "corpus_caches"
require_relative "hyphen"
require_relative "prefix_clusters"
require_relative "lexicon_io"
