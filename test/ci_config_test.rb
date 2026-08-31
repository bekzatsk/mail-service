# frozen_string_literal: true

# Invariants of .flux-ci.yml itself.
#
# The pipeline is a config file, so nothing type-checks it and a mistake only
# shows up on a runner, against production. One such mistake already happened:
# the mirror sat in a YAML folded (>) block, folding kept the newlines of its
# more-indented option lines, a newline inside `lftp -e "..."` separates
# commands, and lftp ran a bare `mirror --reverse` — which defaults to the
# current directory on both sides and uploaded the whole workspace, .git
# included, into the FTP account root.
#
# Every assertion below exists because getting it wrong is expensive and silent.
#
#   ruby test/ci_config_test.rb

require 'yaml'
require_relative 'support/assertions'

CONFIG = File.expand_path('../.flux-ci.yml', __dir__)

abort "#{CONFIG} is missing" unless File.exist?(CONFIG)

doc    = YAML.safe_load(File.read(CONFIG))
stages = doc.delete('stages')
vars   = doc.delete('variables')
jobs   = doc

check = Assertions.method(:check)

puts 'Shape'
check.call('stages are declared', stages.is_a?(Array) && !stages.empty?, true)
check.call('at least one job is defined', jobs.any?, true)

jobs.each do |name, job|
  check.call("#{name}: has a non-empty script", !(job['script'].nil? || job['script'].empty?), true)
  check.call("#{name}: stage is declared in stages", stages.include?(job['stage']), true)
  Array(job['needs']).each do |dep|
    check.call("#{name}: needs #{dep}, which exists", jobs.key?(dep), true)
  end
end

puts "\nUnsupported keys — Flux parses these and then does nothing at all"
%w[before_script after_script rules only except extends default workflow retry parallel environment].each do |key|
  offenders = jobs.select { |_, job| job.key?(key) }.keys
  check.call("no job uses #{key}", offenders, [])
end

puts "\nlftp invocations"
lftp = jobs.values.flat_map { |job| job['script'] }.select { |line| line.include?('lftp -u') }
check.call('exactly two: the pre-flight and the mirror', lftp.size, 2)
# A newline inside lftp -e "..." separates commands. This is the bug above.
check.call('neither spans more than one line', lftp.none? { |l| l.include?("\n") }, true)
check.call('both abort on a failed lftp command', lftp.all? { |l| l.include?('cmd:fail-exit yes') }, true)
check.call('both force TLS', lftp.all? { |l| l.include?('ftp:ssl-force yes') }, true)

mirror = lftp.find { |line| line.include?('mirror') } || ''
check.call('mirror cds into the target first', mirror.include?('cd $MAIL_REMOTE_DIR; mirror'), true)
check.call('mirror names source and target explicitly', mirror.match?(/mirror --reverse.*\$EXCLUDES \. \.;/), true)
# The host holds .env, vendor/ and tmp/, none of which are in this repo.
check.call('mirror never prunes', mirror.include?('--delete'), false)

puts "\nExcluded from the upload"
excludes = jobs.values.flat_map { |job| job['script'] }.find { |l| l.start_with?('EXCLUDES=') } || ''
%w[.git/ .idea/ .claude-flow/ node_modules/ vendor/ tmp/ test/ script/ .env .flux-ci.yml].each do |glob|
  check.call(glob, excludes.include?("--exclude-glob #{glob}"), true)
end

puts "\nDeploy safety"
deploy = jobs['deploy-ftps']
check.call('deploy exists', !deploy.nil?, true)
check.call('deploy is manual', deploy['when'], 'manual')
check.call('deploy waits on every check', Array(deploy['needs']).sort,
           %w[console-smoke pipeline-config route-auth secret-scan])
# A protected secret is an empty string on a non-protected ref and still
# overrides the fallback in this file, so each value has to be guarded.
%w[FLUX_FTP_USER FLUX_FTP_PASS FLUX_FTP_HOST MAIL_SITE_URL].each do |name|
  guarded = deploy['script'].any? { |l| l.include?(%(test -n "${#{name}:-}")) }
  check.call("#{name} is guarded before use", guarded, true)
end

puts "\nNo path filtering"
# A skipped job skips everything that needs it, and deploy needs all the checks,
# so a `changes:` on any of them would silently skip the deploy.
check.call('no job declares changes:', jobs.select { |_, j| j.key?('changes') }.keys, [])

puts "\nRequired variables"
%w[FLUX_FTP_HOST MAIL_REMOTE_DIR MAIL_SITE_URL].each do |name|
  check.call("#{name} has a value", !vars[name].to_s.empty?, true)
end

Assertions.report('ci config')
