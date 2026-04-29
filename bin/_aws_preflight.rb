# frozen_string_literal: true

# Shared AWS pre-flight for dev scripts that hit AWS APIs (currently
# +bin/upload-to-dynamodb+ and +bin/augment-related-from-feedback+ (DynamoDB
# by default; +--from-file+ skips AWS); any future
# +bin/<verb>-...-aws+ should reuse this rather than re-rolling the
# +AWS_PROFILE+ check).
#
# Why a separate helper:
#
#   1. Cross-account safety. An unset +AWS_PROFILE+ lets the SDK's default
#      credential chain pick whichever cached SSO session, env-var pair, or
#      +[default]+ profile it sees first. The original deploy attempt for
#      this stack landed in a work account because of exactly that — the
#      +iam:CreateRole+ denial was the only signal. The +require_profile!+
#      abort + the +identity!+ STS round-trip make wrong-account runs loud
#      *before* the first table operation, instead of after.
#
#   2. The abort message echoes back the user's original CLI flags so the
#      suggested re-run is copy-pasteable. That requires snapshotting +ARGV+
#      *before* +OptionParser#parse!+ mutates it; callers do that, then pass
#      +original_argv+ in.
#
# Layout: lives in +bin/+, not +lib/+, deliberately. +bin/stage-lambda+
# +cp -R lib+'s the entire +lib/+ tree into the deploy bundle, so a
# +lib/rhymecrime/dev_aws_preflight.rb+ would ship to Lambda even though it's
# strictly dev-side. +bin/+ is excluded from staging (see the comment block
# in +stage-lambda+), so dropping the helper here keeps it out of prod by
# construction.
#
# Not loaded at Lambda runtime: +require "aws-sdk-sts"+ is fine here because
# +aws-sdk-sts+ is in the dev/test Gemfile group only — see +Gemfile+.

require "aws-sdk-sts"

module AwsPreflight
  module_function

  # Aborts with a copy-pasteable re-run hint when +AWS_PROFILE+ is unset;
  # otherwise returns the resolved profile string.
  #
  # +script_name+   basename of the calling script (e.g. +"upload-to-dynamodb"+),
  #                 used to build the suggested re-run command.
  # +original_argv+ the +ARGV+ snapshot the caller took before +OptionParser#parse!+.
  def require_profile!(script_name:, original_argv:)
    profile = ENV["AWS_PROFILE"].to_s
    return profile unless profile.empty?

    suggested = "AWS_PROFILE=paceheart ./bin/#{script_name}"
    suggested += " " + original_argv.join(" ") unless original_argv.empty?

    abort <<~MSG
      Error: AWS_PROFILE is required.

      This script reads or writes DynamoDB tables in your AWS account. Without
      an explicit profile, the AWS SDK picks whichever credentials its default
      chain finds first — exactly how previous deploys for this app accidentally
      hit a work-account stack, and how a +Scan+ against the wrong account
      silently returns zero items.

      Re-run with the profile pointing at your personal AWS account:

        #{suggested}

      Available profiles on this machine: +aws configure list-profiles+.
    MSG
  end

  # +GetCallerIdentity+ pre-flight: cheap (single STS call, no IAM perms
  # beyond +sts:GetCallerIdentity+ which is implicit for any authenticated
  # principal), and the printed account+arn line is what the user greps for
  # in shell history when retracing a deploy. +profile+ is passed explicitly
  # to the client constructor (rather than relying on env-var pickup) as
  # belt-and-suspenders against a stray +unset AWS_PROFILE+ between the
  # +require_profile!+ guard and the first call.
  #
  # Wrapped in a +rescue StandardError+ to convert credential-resolution
  # failures from a 60-line SDK stack trace into a one-line summary plus a
  # short menu of likely fixes. The important failure modes are:
  #
  #   * Expired SSO token (+Aws::Errors::InvalidSSOCredentials+ during
  #     +Client.new+, or a +ArgumentError "Cached SSO Token is expired."+
  #     from +Aws::SSOCredentials#read_cached_token+ depending on which
  #     code path the SDK takes — both happen before the network call).
  #     Fix: +aws sso login --profile <profile>+. Only valid for SSO
  #     profiles; on an IAM-user profile this errors with "Missing... sso_start_url".
  #   * Wrong profile (work-account env-var pickup, +production-admin+
  #     etc. set in the parent shell from an earlier session). Fix: re-run
  #     with the correct profile, +AWS_PROFILE=paceheart+ for this repo.
  #   * Profile doesn't exist (+Aws::Errors::NoSuchProfileError+) or is
  #     missing required keys. Fix: +aws configure list-profiles+ /
  #     +aws configure list --profile <profile>+.
  #
  # Catching +StandardError+ broadly is OK here because every exception
  # raised between +Client.new+ and +get_caller_identity+ in this code
  # path is a credential-resolution issue — there's no business logic
  # that could plausibly raise a different class. The original error
  # class+message is preserved verbatim in the abort body so a missed
  # case is still debuggable from the printed line.
  def identity!(profile:, region:)
    Aws::STS::Client.new(region: region, profile: profile).get_caller_identity
  rescue StandardError => e
    abort <<~MSG
      Error: AWS_PROFILE=#{profile.inspect} cannot resolve usable credentials.

      Pre-flight STS call failed before any DynamoDB I/O:
        #{e.class}: #{e.message.lines.first.to_s.strip}

      Likely fixes (try in order):

        1. SSO session expired (the +production-admin+ / +later-*+ profiles use SSO):
             aws sso login --profile #{profile}

        2. Wrong profile in your shell env (a work profile leaked in from an
           earlier session). Re-run with the personal profile that owns this app:
             AWS_PROFILE=paceheart ./bin/<script-name>

        3. Profile is missing or misconfigured:
             aws configure list-profiles | grep #{profile}
             aws configure list --profile #{profile}

      The pre-flight aborts here on purpose — it's better to fail loud now
      than silently hit the wrong AWS account on the first table operation.
    MSG
  end

  # Convenience: profile guard + STS + the banner line every caller prints
  # verbatim. Returns +[profile, identity]+ so callers can keep printing
  # script-specific context (region, table, output paths, etc.) on follow-up
  # lines without re-deriving anything.
  def preflight!(script_name:, original_argv:, region:)
    profile = require_profile!(script_name: script_name, original_argv: original_argv)
    identity = identity!(profile: profile, region: region)
    puts "==> AWS_PROFILE=#{profile} → account=#{identity.account} arn=#{identity.arn}"
    [profile, identity]
  end
end
