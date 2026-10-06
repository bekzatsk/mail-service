# frozen_string_literal: true

require 'ipaddr'
require 'socket'
require 'uri'

module Services
  # Decides whether this service may POST to a URL a tenant supplied.
  #
  # Handler URLs (telegram_commands.handler_url, client_telegram_bots
  # .message_handler_url) are set by API clients and called by us, with the
  # inbound Telegram message as the body and the handler's reply forwarded into
  # the chat. Without a policy, that is a request-forgery primitive: a tenant
  # points a handler at 127.0.0.1, a cloud metadata address or a host on the
  # internal network, and reads whatever it answers from their Telegram chat.
  #
  # Two checks, both needed:
  #   - at write time, so a bad URL is rejected with a 400 the caller sees;
  #   - at delivery time, resolving the host and pinning the connection to the
  #     address that passed, so a DNS record that later flips to a private
  #     address (rebinding) cannot get past the write-time check.
  #
  # Only http and https, only default or high ports, never a literal or
  # resolved address inside a private, loopback, link-local, multicast or
  # otherwise non-public range.
  module OutboundUrlPolicy
    class Rejected < StandardError; end

    SCHEMES = %w[http https].freeze

    # Public-internet addresses only. IPv4-mapped IPv6 is unwrapped before the
    # check so ::ffff:127.0.0.1 does not get past as "an IPv6 address".
    BLOCKED = [
      '0.0.0.0/8',        # "this" network
      '10.0.0.0/8',       # private
      '100.64.0.0/10',    # carrier-grade NAT
      '127.0.0.0/8',      # loopback
      '169.254.0.0/16',   # link-local, cloud metadata
      '172.16.0.0/12',    # private
      '192.0.0.0/24',     # IETF protocol assignments
      '192.0.2.0/24',     # TEST-NET-1
      '192.168.0.0/16',   # private
      '198.18.0.0/15',    # benchmarking
      '198.51.100.0/24',  # TEST-NET-2
      '203.0.113.0/24',   # TEST-NET-3
      '224.0.0.0/4',      # multicast
      '240.0.0.0/4',      # reserved, broadcast
      '::/128',           # unspecified
      '::1/128',          # loopback
      '::ffff:0:0/96',    # IPv4-mapped (unwrapped above, blocked if it survives)
      '64:ff9b::/96',     # NAT64
      '100::/64',         # discard
      '2001:db8::/32',    # documentation
      'fc00::/7',         # unique local
      'fe80::/10',        # link-local
      'ff00::/8'          # multicast
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    module_function

    # Parses and validates a URL string. Returns the URI on success.
    # @raise [Rejected] with a message safe to show the caller
    def parse!(raw)
      text = raw.to_s.strip
      raise Rejected, 'URL is required' if text.empty?
      raise Rejected, 'URL must not contain whitespace or control characters' if text.match?(/[\s[:cntrl:]]/)

      uri = begin
        URI.parse(text)
      rescue URI::InvalidURIError
        raise Rejected, 'URL is not valid'
      end

      raise Rejected, 'URL must be http or https' unless SCHEMES.include?(uri.scheme.to_s.downcase)
      raise Rejected, 'URL must have a host' if uri.host.to_s.empty?
      raise Rejected, 'URL must not carry credentials' if uri.userinfo
      raise Rejected, 'URL port is not allowed' unless uri.port == uri.default_port || uri.port >= 1024

      host = uri.hostname.to_s
      raise Rejected, 'URL host is not allowed' if host.casecmp?('localhost') || host.end_with?('.localhost', '.local', '.internal')

      literal = ip_literal(host)
      raise Rejected, 'URL host resolves to a non-public address' if literal && blocked?(literal)

      uri
    end

    # Validates at write time: syntax, then a DNS lookup so a hostname that
    # points at a private address is refused up front.
    def validate!(raw)
      uri = parse!(raw)
      resolve!(uri.hostname)
      uri
    end

    # Resolves a hostname and returns one public address to connect to.
    # Every address the name resolves to has to be public: a name that mixes a
    # public and a private record is refused rather than guessed about.
    # @raise [Rejected]
    def resolve!(host)
      literal = ip_literal(host)
      if literal
        raise Rejected, 'URL host resolves to a non-public address' if blocked?(literal)

        return literal.to_s
      end

      addresses = begin
        Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map { |ai| IPAddr.new(ai.ip_address) }
      rescue SocketError
        raise Rejected, 'URL host does not resolve'
      end
      raise Rejected, 'URL host does not resolve' if addresses.empty?
      raise Rejected, 'URL host resolves to a non-public address' if addresses.any? { |ip| blocked?(ip) }

      addresses.first.to_s
    end

    def blocked?(ip)
      ip = ip.ipv4_mapped? ? ip.native : ip
      BLOCKED.any? { |range| range.include?(ip) }
    rescue StandardError
      true
    end

    def ip_literal(host)
      IPAddr.new(host.to_s.delete_prefix('[').delete_suffix(']'))
    rescue IPAddr::Error, ArgumentError
      nil
    end
  end
end
