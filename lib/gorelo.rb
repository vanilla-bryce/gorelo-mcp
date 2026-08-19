# frozen_string_literal: true

# Gorelo API client - plain Ruby stdlib.
#
# The awkward parts of the API, all of which are load-bearing:
#   - PascalCase fields
#   - an envelope: { StatusCode, IsSuccess, Data, DataContext, Notifications }
#   - CURSOR pagination via DataContext.Pagination.NextCursor / HasMore
#     (a `page` parameter is silently ignored, which loops forever)
#   - PageSize is clamped to 1..200
#   - /v1/contacts filters on ClientId (singular); /v1/tickets on ClientIds
#   - /v1/assets/agents has no client filter at all

require 'net/http'
require 'uri'
require 'json'
require 'digest'
require 'time'
require 'fileutils'

module Gorelo
  class Error < StandardError; end
  class AuthError < Error; end
  class WritesDisabled < Error; end

  # A failure that waiting might fix: rate limits and server faults.
  class RetryableError < Error
    attr_reader :retry_after, :short

    def initialize(message, short:, retry_after: nil)
      super(message)
      @short = short
      @retry_after = retry_after
    end
  end

  # Gorelo's BaseStatusId semantics, from /v1/tickets/statuses.
  # 3 is a "solved" BASE, but custom statuses such as "Standing Ticket" and
  # "Billing" commonly live under it - so filtering on base 3 as "done" hides
  # real outstanding work. Never treat base 3 as finished.
  BASE_NEW     = 1
  BASE_OPEN    = 2
  BASE_SOLVED  = 3
  BASE_CLOSED  = 4
  BASE_ON_HOLD = 6

  ACTIVE_BASES = [BASE_NEW, BASE_OPEN, BASE_ON_HOLD].freeze

  BASE_NAMES = {
    BASE_NEW => 'New', BASE_OPEN => 'Open', BASE_SOLVED => 'Solved-base',
    BASE_CLOSED => 'Closed', BASE_ON_HOLD => 'On Hold'
  }.freeze

  class Client
    MAX_PAGES = 200
    # Gorelo clamps PageSize to 1..200. Overridable so pagination can be
    # exercised against a small dataset without waiting for a big one.
    PAGE_SIZE = (ENV['GORELO_PAGE_SIZE'] || 200).to_i.clamp(1, 200)

    attr_reader :base_url

    def initialize(api_key:, base_url: 'https://api.aue.gorelo.io',
                   allow_writes: false, logger: nil, write_log_path: nil)
      raise Error, 'GORELO_API_KEY is not set' if api_key.nil? || api_key.strip.empty?

      @api_key        = api_key.strip
      @base_url       = base_url.chomp('/')
      @allow_writes   = allow_writes
      @logger         = logger || ->(m) { warn "[gorelo] #{m}" }
      @write_log_path = write_log_path || File.join(Dir.home, '.gorelo-mcp-writes.jsonl')
      @cache          = {}
    end

    def writes_allowed? = @allow_writes

    # ---- HTTP -------------------------------------------------------------

    def get(path, query = {})
      request(Net::HTTP::Get, path, query: query)
    end

    def post(path, body, query = {})
      unless @allow_writes
        raise WritesDisabled,
              'Writes are disabled. Set GORELO_ALLOW_WRITES=true in .env and restart ' \
              'the client to enable the one write tool.'
      end
      request(Net::HTTP::Post, path, query: query, body: body)
    end

    # Follows DataContext.Pagination.NextCursor until exhausted. `limit` stops
    # early once enough rows are in hand - most calls do not need every
    # contact in the tenant, and pulling them wastes context as well as time.
    def get_all(path, query = {}, limit: nil)
      rows        = []
      cursor      = nil
      last_cursor = :none
      pages       = 0

      loop do
        pages += 1
        break if pages > MAX_PAGES

        q = query.merge('PageSize' => PAGE_SIZE)
        q['Cursor'] = cursor if cursor

        body  = get(path, q)
        batch = Array(body['Data'])
        rows.concat(batch)

        return rows.first(limit) if limit && rows.size >= limit

        pagination = body.dig('DataContext', 'Pagination') || {}
        cursor     = pagination['NextCursor']
        has_more   = pagination['HasMore']

        break if batch.empty? || cursor.nil? || has_more == false
        # A cursor that stops advancing would otherwise spin until MAX_PAGES.
        break if cursor == last_cursor

        last_cursor = cursor
      end

      @logger.call("#{path}: #{rows.size} rows over #{pages} page(s)") if pages > 1
      rows
    end

    # ---- cached lookups ---------------------------------------------------

    def statuses
      @cache[:statuses] ||= begin
        rows = Array(get('/v1/tickets/statuses')['Data'])
        rows.each_with_object({}) { |s, h| h[s['Id'].to_s] = s }
      end
    end

    def base_status_id(status_id)
      statuses.dig(status_id.to_s, 'BaseStatusId')
    end

    # Every status except the closed base, built from the live status list so a
    # status added in Gorelo tomorrow is picked up without a code change.
    #
    # Used ONLY to scope the org-wide sweep for tickets you assist on but do
    # not lead - Gorelo has no AssistingAssigneeIds filter, so the alternative
    # is paging all ~4,000 tickets. It is never used to filter your own
    # tickets, because a server-side status filter cannot return a status it
    # has never heard of (Merged, id 5, is exactly that).
    def unclosed_status_ids
      statuses.values.reject { |s| s['BaseStatusId'] == BASE_CLOSED }.map { |s| s['Id'] }
    end

    GUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    # `Query` is the documented search parameter: "Keyword matched against the
    # ticket title, number and display number. Up to 200 characters."
    # A GUID goes straight to /v1/tickets/{id}.
    def ticket_by_number(reference)
      key = reference.to_s.strip.sub(/\AG-/i, '')
      return nil if key.empty?
      return get("/v1/tickets/#{key}")['Data'] if key.match?(GUID)

      rows = Array(get('/v1/tickets', { 'Query' => key, 'PageSize' => 25 })['Data'])

      # Query matches titles as well as numbers, so prefer an exact number or
      # display-number match before falling back to a single title hit.
      rows.find { |t| t['Number'].to_s == key } ||
        rows.find { |t| t['DisplayNumber'].to_s.casecmp?(reference.to_s.strip) } ||
        (rows.size == 1 ? rows.first : nil)
    end

    def clients
      @cache[:clients] ||= get_all('/v1/clients')
    end

    def client_name(client_id)
      return nil if client_id.nil?

      @cache[:client_names] ||= clients.each_with_object({}) do |c, h|
        h[c['Id'].to_s] = c['Name'] || c['CompanyName'] || c['ClientName']
      end
      @cache[:client_names][client_id.to_s]
    end

    def users
      @cache[:users] ||= get_all('/v1/organization/users')
    end

    # Resolves "me", an email, a name fragment or a numeric id to a user id.
    def resolve_user_id(who)
      return nil if who.nil? || who.to_s.strip.empty?

      who = who.to_s.strip
      return who if who =~ /\A\d+\z/

      needle = who.downcase
      needle = (ENV['GORELO_MY_EMAIL'] || '').downcase if needle == 'me'
      raise Error, 'Asked for "me" but GORELO_MY_EMAIL is not set in .env' if needle.empty?

      match = users.find { |u| blob(u).include?(needle) }
      raise Error, "No Gorelo user matches #{who.inspect}" unless match

      match['Id']
    end

    # Resolves a client name fragment or numeric id to a list of client records.
    # Accepts comma-separated terms, because one account is often known by
    # two names that share no substring (a trading name and an acronym).
    def resolve_clients(term)
      return [] if term.nil? || term.to_s.strip.empty?

      terms = term.to_s.split(',').map { |t| t.strip.downcase }.reject(&:empty?)
      clients.select do |c|
        blob = [c['Id'], c['Name'], c['CompanyName'], c['ClientName']].compact.join(' ').downcase
        terms.any? { |t| blob.include?(t) }
      end
    end

    # ---- write guard ------------------------------------------------------

    # No SSE resumability in the current MCP spec means a retried call can post
    # the same comment twice. A local fingerprint log makes the write
    # effectively idempotent without needing anything from Gorelo.
    def write_fingerprint_seen?(key)
      return false unless File.exist?(@write_log_path)

      cutoff = Time.now - (24 * 3600)
      File.foreach(@write_log_path).any? do |line|
        row = JSON.parse(line) rescue nil
        next false unless row && row['key'] == key

        (Time.parse(row['at']) > cutoff rescue false)
      end
    end

    def record_write(key, detail)
      FileUtils.mkdir_p(File.dirname(@write_log_path))
      File.open(@write_log_path, 'a') do |f|
        f.puts JSON.generate('key' => key, 'at' => Time.now.utc.iso8601, 'detail' => detail)
      end
    end

    def fingerprint(*parts)
      Digest::SHA256.hexdigest(parts.map(&:to_s).join('|'))[0, 32]
    end

    private

    def blob(user)
      [user['Id'], user['Email'], user['EmailAddress'], user['Name'],
       user['FirstName'], user['LastName'], user['DisplayName']].compact.join(' ').downcase
    end

    def request(klass, path, query: {}, body: nil)
      uri = URI.join("#{@base_url}/", path.sub(%r{\A/}, ''))
      pairs = query.reject { |_, v| v.nil? || v.to_s.empty? }
      uri.query = URI.encode_www_form(pairs) unless pairs.empty?

      req = klass.new(uri)
      req['X-API-Key']    = @api_key
      req['Accept']       = 'application/json'
      req['User-Agent']   = 'amit-gorelo-mcp/1.0'
      if body
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == 'https'
      http.open_timeout = 15
      http.read_timeout = 60

      with_retry(path) { handle(http.request(req), uri) }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise Error, "Gorelo timed out calling #{path}: #{e.class}"
    rescue SocketError => e
      raise Error, "Cannot reach #{@base_url}: #{e.message}"
    end

    # Gorelo rate-limits, and says how long to wait:
    #   {"error":"Rate limit exceeded","retry_after":"1s"}
    # Retry only what is safe to retry - a rate limit or a server fault. A 404
    # or a bad API key is retried never, because waiting cannot fix it.
    def with_retry(path)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue RetryableError => e
        raise Error, "#{e.message} (gave up after #{attempt} attempts)" if attempt >= 4

        delay = e.retry_after || (0.5 * (2**(attempt - 1)))
        @logger.call("#{path}: #{e.short}, waiting #{delay}s then retrying (#{attempt}/3)")
        sleep(delay)
        retry
      end
    end

    def handle(res, uri)
      code = res.code.to_i

      # Auth failures must always surface plainly. Reporting them as "no data"
      # once cost an afternoon of chasing a pagination ghost.
      if [401, 403].include?(code)
        raise AuthError, "Gorelo rejected the API key (HTTP #{code}) on #{uri.path}. " \
                         'Check GORELO_API_KEY and that its scope covers this endpoint.'
      end

      parsed = begin
        JSON.parse(res.body.to_s)
      rescue JSON::ParserError
        nil
      end

      unless code.between?(200, 299)
        detail = parsed ? summarise_notifications(parsed) : res.body.to_s[0, 400]
        message = "Gorelo returned HTTP #{code} for #{uri.path}: #{detail}"

        if code == 429 || code >= 500
          raise RetryableError.new(message, short: "HTTP #{code}",
                                            retry_after: retry_after_seconds(res, parsed))
        end

        raise Error, message
      end

      raise Error, "Gorelo returned a non-JSON body for #{uri.path}" if parsed.nil?

      if parsed.key?('IsSuccess') && parsed['IsSuccess'] == false
        raise Error, "Gorelo reported failure for #{uri.path}: #{summarise_notifications(parsed)}"
      end

      parsed
    end

    # Prefer the Retry-After header, fall back to the body's "1s" style value.
    def retry_after_seconds(res, parsed)
      header = res['Retry-After']
      return header.to_f if header && header.to_f.positive?

      body = parsed.is_a?(Hash) ? parsed['retry_after'].to_s : ''
      seconds = body[/[\d.]+/]
      seconds ? [seconds.to_f, 30].min : nil
    end

    def summarise_notifications(parsed)
      notes = Array(parsed['Notifications']).map do |n|
        n.is_a?(Hash) ? (n['Message'] || n['Detail'] || n.to_s) : n.to_s
      end
      notes.empty? ? parsed.to_s[0, 400] : notes.join('; ')
    end
  end
end
