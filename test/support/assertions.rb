# frozen_string_literal: true

# Assertion helper. Deliberately dependency-free: these tests must run on a bare
# ruby image with no bundle and no gems installed.
module Assertions
  class << self
    def results = @results ||= []

    def check(description, actual, expected)
      ok = actual == expected
      results << ok
      status = ok ? 'ok' : "FAIL (expected #{expected.inspect}, got #{actual.inspect})"
      puts format('  %-62s %s', description, status)
      ok
    end

    def report(suite)
      failures = results.count(false)
      puts
      if failures.zero?
        puts "#{suite}: all #{results.size} checks pass"
        exit 0
      else
        puts "#{suite}: #{failures} of #{results.size} checks FAILED"
        exit 1
      end
    end
  end
end
