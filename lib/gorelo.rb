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
#   - /v1/assets/agents gained ClientIds filtering on 2026-08-21; before
#     that it had no filters at all and the whole fleet had to be paged
#   - the 2026-09-04 release added /v1/time-entries, /v1/contracts,
#     /v1/billing-roles and /v1/work-types. The first two paginate the same
#     way; the last two are small unpaginated reference tables.
#   - CONTRACT TERMINOLOGY IS INVERTED between the API and the web UI. An API
#     `contract` is what the UI calls a "Contract Group" (the invoice), and an
#     API `ServiceLine` is what the UI calls a "Contract". Gorelo has said it
#     will align the UI to the API eventually. Until then, never print one
#     word without the other.

require 'net/http'
require 'openssl'
require 'uri'
require 'json'
require 'digest'
require 'time'
require 'fileutils'
require 'securerandom'

module Gorelo
  class Error < StandardError; end
  class AuthError < Error; end
  class WritesDisabled < Error; end

  # A POST whose outcome is unknown: a 5xx, a read timeout, a connection
  # dropped or reset after the body went out, or a 2xx whose reply could not be
  # read. It MAY have been applied, so it is never retried: retrying a POST that
  # did land raises a second invoice or posts a second comment.
  class AmbiguousWrite < Error; end

  # A non-2xx reply that Gorelo actually sent, carrying its status. A 4xx means
  # Gorelo refused the request; callers may rely on that to say "not applied".
  class HttpError < Error
    attr_reader :status

    def initialize(message, status:)
      super(message)
      @status = status
    end
  end

  # Transport failures that can happen AFTER a request body went out. On a POST
  # each one leaves the outcome unknown. (OpenTimeout and SocketError cannot:
  # they happen before anything is sent.)
  TRANSPORT_ERRORS = [IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::WriteTimeout].freeze

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
    # Overridable so the test suite can force a read timeout without waiting a minute.
    READ_TIMEOUT = (ENV['GORELO_READ_TIMEOUT'] || 60).to_i.clamp(1, 300)

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
      @requests       = 0
    end

    def writes_allowed? = @allow_writes

    # Every HTTP call this client makes, retries included. Tools quote it so a
    # stated cost is measured rather than estimated.
    def requests = @requests

    def guard_writes!
      return if @allow_writes

      raise WritesDisabled,
            'Writes are disabled. Set GORELO_ALLOW_WRITES=true in .env and restart ' \
            'the client to enable the write tools.'
    end

    # ---- HTTP -------------------------------------------------------------

    def get(path, query = {})
      request(Net::HTTP::Get, path, query: query)
    end

    # A file download. Its ERRORS still arrive as the JSON envelope; its
    # success is the file itself. Returns Body (binary), ContentType, Filename.
    def get_binary(path, query = {})
      request(Net::HTTP::Get, path, query: query, raw: true)
    end

    def post(path, body, query = {})
      guard_writes!
      request(Net::HTTP::Post, path, query: query, body: body)
    end

    # multipart/form-data upload. The body is built in memory, so a request
    # retried after a 429 sends the same bytes again. Files are capped at
    # 44 MB before this is called.
    def post_multipart(path, fields, file_path)
      guard_writes!
      boundary = "gorelo-mcp-#{SecureRandom.hex(16)}"
      name     = File.basename(file_path).gsub(/["\r\n\\]/, '_')
      body     = String.new(encoding: Encoding::BINARY)
      fields.each do |k, v|
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{k}\"\r\n\r\n#{v}\r\n".b
      end
      body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{name}\"\r\n" \
              "Content-Type: application/octet-stream\r\n\r\n".b
      body << File.binread(file_path) << "\r\n--#{boundary}--\r\n".b
      request(Net::HTTP::Post, path, raw_body: body,
                                     content_type: "multipart/form-data; boundary=#{boundary}")
    end

    # PATCH exists for tickets, clients and contacts. Only tickets are reachable
    # from this server, and only two fields on them - see gorelo_update_ticket.
    #
    # There is deliberately NO `delete` method on this class. Gorelo now exposes
    # DELETE for tickets, clients, contacts, agent assets, custom assets,
    # private comments and time entries. None of that belongs behind an
    # assistant, and the strongest way to say so is for the verb to be absent
    # rather than merely unused - a tool cannot call a method that does not
    # exist.
    def patch(path, body, query = {})
      guard_writes!
      request(Net::HTTP::Patch, path, query: query, body: body)
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

    def contracts
      @cache[:contracts] ||= get_all('/v1/contracts')
    end

    def taxes
      @cache[:taxes] ||= Array(get('/v1/taxes')['Data'])
    end

    # "GST on Income 10%". A tax with SubTaxes charges the SUM of its
    # components, and its own Percentage is not applied on top (spec, /v1/taxes).
    def tax_label(tax_id)
      return nil if tax_id.nil?

      tax = taxes.find { |t| t['Id'].to_s == tax_id.to_s }
      return "tax #{tax_id}" unless tax

      subs = Array(tax['SubTaxes'])
      pct  = subs.empty? ? tax['Percentage'] : subs.sum { |s| s['Percentage'].to_f }
      pct.nil? ? tax['Name'] : "#{tax['Name']} #{format('%g', pct.to_f)}%"
    end

    def item_categories
      @cache[:item_categories] ||= Array(get('/v1/items/categories')['Data'])
    end

    # Subcategory ids are issued independently of category ids, and one number
    # can name a subcategory under two different categories - so a subcategory
    # is only ever looked up INSIDE its own category.
    def category_label(category_id, subcategory_id)
      return nil if category_id.nil?

      cat = item_categories.find { |c| c['Id'].to_s == category_id.to_s }
      return "category #{category_id}" unless cat

      sub = subcategory_id && Array(cat['Subcategories']).find { |s| s['Id'].to_s == subcategory_id.to_s }
      sub ? "#{cat['Name']} › #{sub['Name']}" : cat['Name']
    end

    def client_name(client_id)
      return nil if client_id.nil?

      @cache[:client_names] ||= clients.each_with_object({}) do |c, h|
        h[c['Id'].to_s] = c['Name'] || c['CompanyName'] || c['ClientName']
      end
      @cache[:client_names][client_id.to_s]
    end

    # A time entry names its TICKET - Ticket {Id, Number, Title} - and carries
    # no client at all, so any per-client view of hours needs a ticket-to-client
    # index. This builds one with a SINGLE paged sweep of /v1/tickets
    # (TotalCount/200 requests, normally a handful) and caches it for the life
    # of the process.
    #
    # The alternative is GET /v1/tickets/{id} per entry, which is exactly the
    # N+1 that /v1/time-entries exists to remove. Do not reintroduce it.
    def ticket_client_index
      @cache[:ticket_client] ||= get_all('/v1/tickets').each_with_object({}) do |t, h|
        h[t['Id'].to_s] = t['ClientId']
      end
    end

    def users
      @cache[:users] ||= get_all('/v1/organization/users')
    end

    def groups
      @cache[:groups] ||= get_all('/v1/organization/groups')
    end

    # Gorelo groups are how separate desks or brands are modelled - each can
    # carry its own outbound helpdesk address - so they are a real reporting
    # dimension, not just an internal routing detail.
    def group_name(group_id)
      return nil if group_id.nil?

      @cache[:group_names] ||= groups.each_with_object({}) { |g, h| h[g['Id'].to_s] = g['Name'] }
      @cache[:group_names][group_id.to_s]
    end

    # Display name for a technician id, for reports that group by assignee.
    def user_name(user_id)
      return nil if user_id.nil?

      @cache[:user_names] ||= users.each_with_object({}) do |u, h|
        name = u['Name'] || u['DisplayName'] ||
               [u['FirstName'], u['LastName']].compact.join(' ').strip
        name = u['Email'] if name.to_s.strip.empty?
        h[u['Id'].to_s] = name
      end
      @cache[:user_names][user_id.to_s]
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

    def request(klass, path, query: {}, body: nil, raw: false, raw_body: nil, content_type: nil)
      @requests += 1
      uri = URI.join("#{@base_url}/", path.sub(%r{\A/}, ''))
      pairs = query.reject { |_, v| v.nil? || v.to_s.empty? }
      uri.query = URI.encode_www_form(pairs) unless pairs.empty?

      req = klass.new(uri)
      req['X-API-Key']    = @api_key
      req['Accept']       = raw ? 'application/pdf, application/json' : 'application/json'
      req['User-Agent']   = 'amit-gorelo-mcp/1.0'
      if raw_body
        req['Content-Type'] = content_type
        req.body = raw_body
      elsif body
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(body)
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = uri.scheme == 'https'
      http.open_timeout = 15
      http.read_timeout = READ_TIMEOUT

      post = klass == Net::HTTP::Post
      with_retry(path) { handle(http.request(req), uri, raw: raw, retry_5xx: !post, post: post) }
    rescue Net::ReadTimeout => e
      # Nothing was sent yet on an OpenTimeout, but a ReadTimeout on a POST
      # happens AFTER the body went out - Gorelo may have applied it. Exactly
      # as ambiguous as a 5xx, so it is never retried either.
      if klass == Net::HTTP::Post
        raise AmbiguousWrite, "Gorelo timed out waiting for a reply to #{path} (#{e.class}).\n  " \
                              'Not retried: this was a POST, and the request may have been applied. ' \
                              'Check Gorelo before trying again.'
      end
      raise Error, "Gorelo timed out calling #{path}: #{e.class}"
    rescue Errno::ECONNREFUSED => e
      # Refused at connect: nothing was sent, so nothing can have been applied.
      raise Error, "Cannot reach #{@base_url}: #{e.message}"
    rescue *TRANSPORT_ERRORS => e
      # EOFError, ECONNRESET, EPIPE, an SSL failure or a write timeout: the
      # connection broke mid-exchange. On a POST the body may already have been
      # received and acted on, so this is exactly as ambiguous as a timeout.
      if klass == Net::HTTP::Post
        raise AmbiguousWrite, "The connection to Gorelo failed during #{path} (#{e.class}: #{e.message}).\n  " \
                              'Not retried: this was a POST, and the request may have been applied. ' \
                              'Check Gorelo before trying again.'
      end
      raise Error, "The connection to Gorelo failed calling #{path}: #{e.class}: #{e.message}"
    rescue Net::OpenTimeout => e
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

    def handle(res, uri, raw: false, retry_5xx: true, post: false)
      code = res.code.to_i

      # Auth failures must always surface plainly. Reporting them as "no data"
      # once cost an afternoon of chasing a pagination ghost.
      if [401, 403].include?(code)
        raise AuthError, "Gorelo rejected the API key (HTTP #{code}) on #{uri.path}. " \
                         'Check GORELO_API_KEY and that its scope covers this endpoint.'
      end

      # A file download succeeds with the file itself - only its errors use the
      # envelope - so a 2xx that isn't JSON is the answer, not a fault.
      if raw && code.between?(200, 299) && !res['Content-Type'].to_s.include?('json')
        return { 'Body'        => res.body.to_s.b,
                 'ContentType' => res['Content-Type'].to_s,
                 'Filename'    => res['Content-Disposition'].to_s[/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i, 1] }
      end

      parsed = begin
        JSON.parse(res.body.to_s)
      rescue JSON::ParserError
        nil
      end

      unless code.between?(200, 299)
        detail = parsed ? summarise_notifications(parsed) : res.body.to_s[0, 400]
        message = "Gorelo returned HTTP #{code} for #{uri.path}: #{detail}"

        # 405 is the single most informative status this API returns, and it
        # arrives with an empty body, so it has to be explained here or it
        # reads as a dead end.
        #
        # 404 = no route of ANY method matches that path.
        # 405 = the route EXISTS but does not accept this verb.
        #
        # That difference is how you map an undocumented surface without
        # guessing: GET a candidate path, and a 405 proves the endpoint is real
        # even though this server will only ever read from it. It is how
        # /v1/tickets/{id}/time-entries/{id} was confirmed to exist as a
        # DELETE-only route.
        #
        # CORRECTION (2026-09-11): that route being DELETE-only was once read
        # here as "time entries cannot be read at all". It never meant that,
        # and since the 2026-09-04 release the tenant-wide collection
        # GET /v1/time-entries returns every entry. A 405 tells you about ONE
        # path and one verb, never about a feature.
        if code == 405
          raise HttpError.new("#{message}\n  405 means this PATH EXISTS but does not accept GET - " \
                              "it is defined for another verb (POST, PATCH or DELETE).\n  This server " \
                              'only ever issues GET, so the endpoint is real but not readable from here.',
                              status: 405)
        end

        # A 429 was never processed, so it is always safe to retry. A 5xx on a
        # POST may have been processed, so it is not.
        if code >= 500 && !retry_5xx
          raise AmbiguousWrite, "#{message}\n  Not retried: this was a POST, and a server error " \
                                'does not say whether it was applied. Check Gorelo before trying again.'
        end

        if code == 429 || code >= 500
          raise RetryableError.new(message, short: "HTTP #{code}",
                                            retry_after: retry_after_seconds(res, parsed))
        end

        raise HttpError.new(message, status: code)
      end

      if parsed.nil?
        # Gorelo accepted the POST (2xx) and then said something unreadable: it
        # was very probably applied, and there is no id to prove it either way.
        if post
          raise AmbiguousWrite, "Gorelo accepted #{uri.path} (HTTP #{code}) but its reply was not JSON, " \
                                "so the result is unknown.\n  Not retried: this was a POST, and the " \
                                'request was probably applied. Check Gorelo before trying again.'
        end
        raise Error, "Gorelo returned a non-JSON body for #{uri.path}"
      end

      if parsed.key?('IsSuccess') && parsed['IsSuccess'] == false
        raise Error, "Gorelo reported failure for #{uri.path}: #{summarise_notifications(parsed)}"
      end

      raise Error, "Gorelo returned JSON where #{uri.path} should return a file." if raw

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
