# Regression: when Sinatra/Puma serves multiple requests concurrently, each request's HTML
# output buffer must be thread-local. With a process-wide $html_output_buffer, one request's
# cgi_print / emit_line output leaks into the other request's response body (the bug that
# caused a fidget query's rhyming-word-sets to appear inside a pirate query's HTML).

require "rhymecrime/frontend/frontend"

RSpec.describe "thread-local HTML output buffer" do
  def drive_writer(tag, iters)
    buf = +""
    Thread.current[:html_output_buffer] = buf
    iters.times do
      cgi_print "<a>#{tag}</a>"
      emit_text "text:#{tag};"
      emit_line "line:#{tag}"
    end
    buf
  ensure
    Thread.current[:html_output_buffer] = nil
  end

  # Many threads, many iterations, many distinct tags → thread scheduling alone almost guarantees
  # interleaving. A shared global buffer would cross-contaminate; a thread-local one cannot.
  it "keeps concurrent writers' output isolated" do
    # Tags chosen so none is a substring of any other (keeps the leak-detection check simple).
    tags = %w[alpha bravo delta gamma kilo november quebec zulu]
    iters = 500

    threads = tags.map do |tag|
      Thread.new { drive_writer(tag, iters) }
    end
    results = threads.map(&:value)

    results.each_with_index do |buf, i|
      my_tag = tags[i]
      other_tags = tags - [my_tag]

      expect(buf.scan("<a>#{my_tag}</a>").size).to eq(iters),
        "expected #{iters} <a> writes for #{my_tag}, got #{buf.scan("<a>#{my_tag}</a>").size}"
      expect(buf.scan("text:#{my_tag};").size).to eq(iters)
      expect(buf.scan("line:#{my_tag}\n").size).to eq(iters)

      other_tags.each do |other|
        expect(buf).not_to include(other),
          "thread for #{my_tag} leaked content tagged #{other}"
      end
    end
  end

  it "falls through to stdout when no buffer is set on the current thread" do
    Thread.current[:html_output_buffer] = nil
    # Just proves the guard still works; no assertions on stdout content.
    expect { cgi_print "x" }.not_to raise_error
    expect { emit_text "y" }.not_to raise_error
    expect { emit_line "z" }.not_to raise_error
    expect { cgi_puts "w" }.not_to raise_error
  end
end
