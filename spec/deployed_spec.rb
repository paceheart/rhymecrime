# frozen_string_literal: true

# Smoke tests against the *deployed* stack at +rhymecrime.com+. Mirrors the
# curl-based verification checklist from the +cloudfront-http-redirect+
# change: confirms the CloudFront distribution is fronting both the apex
# and the +www+ subdomain, 301-redirects port 80 to 443, and still proxies
# +POST /feedback+ through to the Lambda.
#
# Hostname is hardcoded — every +rspec+ run hits production, so a deployment
# regression shows up as a red spec the next time anyone runs the suite. If
# you ever need to point at a non-prod stack, edit +HOST+ below; an env-var
# fallback would silently skip on omission and is the exact failure mode
# this hardcode is here to prevent.

require_relative "spec_helper"
require "net/http"
require "uri"
require "json"

RSpec.describe "deployed stack" do
  HOST = "rhymecrime.com"

  # Net::HTTP defaults to follow_redirect = false, which is what we want for
  # the redirect assertions. Per-request +read_timeout+ bumped to 30s to cover
  # a Lambda cold start on a +set_related+-triggering query.
  #
  # All non-POST checks use GET (not HEAD) because the API Gateway HTTP API
  # routes in +template.yaml+ are method-specific (+Method: GET+ — *not*
  # +ANY+), so a HEAD request against +/health+ doesn't match any route and
  # returns 404 instead of the 200 the lambda would emit. Real users / Route
  # 53 health checks / monitoring probes overwhelmingly use GET, so testing
  # GET is the right contract; HEAD support would be a separate decision
  # (would need +Method: ANY+ on every route, or paired HEAD events).
  def http_get(url)
    uri = URI.parse(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30) do |http|
      http.request(Net::HTTP::Get.new(uri.request_uri))
    end
  end

  def http_post_json(url, payload)
    uri = URI.parse(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30) do |http|
      req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
      req.body = JSON.generate(payload)
      http.request(req)
    end
  end

  describe "HTTPS (status quo)" do
    # +/health+ surfaces the lambda's body in the failure message because a
    # 503 here typically means the lambda *did* run but its
    # +DescribeTable+ probe against DynamoDB raised — and the exception
    # message is the only signal we get about *why* (missing IAM permission,
    # wrong table name, throttling, etc.). Without echoing +response.body+
    # the spec just says "expected 200, got 503" and you're stuck doing a
    # second curl to figure out what happened.
    it "GET https://<apex>/health returns 200" do
      response = http_get("https://#{HOST}/health")
      expect(response.code).to eq("200"), "expected 200, got #{response.code} (body: #{response.body.inspect})"
    end

    it "GET https://www.<apex>/health returns 200" do
      response = http_get("https://www.#{HOST}/health")
      expect(response.code).to eq("200"), "expected 200, got #{response.code} (body: #{response.body.inspect})"
    end
  end

  describe "HTTP -> HTTPS redirect (the new behavior)" do
    it "GET http://<apex>/ 301-redirects to https://<apex>/" do
      response = http_get("http://#{HOST}/")
      expect(response.code).to eq("301")
      expect(response["location"]).to eq("https://#{HOST}/")
    end

    it "GET http://www.<apex>/ 301-redirects to https://www.<apex>/" do
      response = http_get("http://www.#{HOST}/")
      expect(response.code).to eq("301")
      expect(response["location"]).to eq("https://www.#{HOST}/")
    end

    it "GET http://<apex>/?w=crime preserves the query string in the redirect Location" do
      response = http_get("http://#{HOST}/?w=crime")
      expect(response.code).to eq("301")
      # CloudFront +redirect-to-https+ preserves both path and query — we rely
      # on this so bookmarks / pasted +http://+ links don't lose the lookup.
      expect(response["location"]).to eq("https://#{HOST}/?w=crime")
    end

    it "following the redirect for http://<apex>/?w=crime returns 200" do
      response = http_get("https://#{HOST}/?w=crime")
      expect(response.code).to eq("200")
      # Sanity: it's the rhymecrime page, not some interstitial.
      expect(response.body).to include("rhymecrime")
    end
  end

  describe "POST /feedback through CloudFront" do
    # Uses a deliberately invalid verdict so +Rhymecrime::FeedbackStore.record!+
    # rejects the row before any DDB write happens — confirms CloudFront is
    # forwarding POST bodies + headers correctly without leaving a smoke-test
    # row in the feedback table on every CI run. A 400 here means the request
    # made it all the way through CloudFront -> API Gateway -> Lambda and the
    # handler ran; a 5xx would mean the path is broken somewhere in the chain.
    it "POST https://<apex>/feedback with an invalid payload returns 400 (proves the path, no DDB write)" do
      response = http_post_json("https://#{HOST}/feedback", { cue: "", related: "", verdict: "__invalid__" })
      expect(response.code).to eq("400")
    end
  end
end
