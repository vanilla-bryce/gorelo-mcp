# frozen_string_literal: true

# Recoding time entries (Gorelo PATCH /v1/time-entries/{id}), 1 October 2026.
#
# Built for two recurring jobs, each previewed and approved by a person first:
#   - "Assisted <tech>" entries move to the Peer Assist work type (No charge);
#   - entries for labour already sold as a fixed charge move onto a fixed-labour
#     service line (the API's ServiceLine, the UI's "Contract").
#
# READ THIS BEFORE WIDENING IT. The endpoint accepts far more than this tool
# sends (StartedOn, EndedOn, ActualHours, UserId, BillingRoleId). None of that is
# reachable here on purpose: changing hours, dates or the person who did the work
# rewrites the record of what happened, not how it is billed. Only the four
# fields below can be sent, and any other argument is refused rather than
# ignored.
#
# Every change RE-PRICES the entry. A change to work type, billable status or
# service line re-applies the work type's minimum and increment, the role's rate
# and the contract's terms, and moves hours between BlockHours / LimitedHours
# contracts. The preview says so every time.
#
# There is no delete path: Gorelo::Client has no delete method at all.

require 'time'
require 'cgi'
require_relative 'gorelo'
require_relative 'gorelo_tools'

module GoreloTimeEntryTools
  module_function

  def pad(...)    = GoreloTools.pad(...)
  def clip(...)   = GoreloTools.clip(...)
  def nested(...) = GoreloTools.nested(...)

  # Brisbane has no daylight saving, so a fixed offset is exact.
  BRISBANE = '+10:00'

  FIELD_KEYS   = %w[work_type billable_status service_line_id comment append_comment].freeze
  CONTROL_KEYS = %w[id confirm expected_updated_on].freeze
  MAX_BATCH    = 50
  BATCH_DELAY  = (ENV['GORELO_BATCH_DELAY'] || 1.0).to_f

  # There is no endpoint that lists billable statuses (/v1/time-entries/statuses
  # is a 404), so these are the four values observed on real time entries.
  # Id 4 has not been seen on an entry and is deliberately not offered.
  BILLABLE_STATUSES = {
    1 => 'Billable', 2 => 'No charge', 3 => 'Non-billable', 5 => 'Void'
  }.freeze

  REPRICE_WARNING = '⚠ Gorelo RE-PRICES the entry on any of these changes (work type, billable status, ' \
                    "service line): the work type's minimum and increment, the billing role's rate and " \
                    "the contract's terms are applied afresh, and hours drawn from a BlockHours or " \
                    'LimitedHours contract move from the old contract to the new one.'

  def register(server, api)
    update_time_entry(server, api)
    update_time_entries(server, api)
  end

  # ---- helpers --------------------------------------------------------------

  def brisbane(value)
    return '-' if value.to_s.empty?

    Time.parse(value.to_s).getlocal(BRISBANE).strftime('%a %d %b %Y %H:%M') + ' AEST'
  rescue ArgumentError
    value.to_s
  end

  def entry_id(raw)
    s = raw.to_s.strip
    s.match?(/\A\d+\z/) ? s : nil
  end

  def fetch_entry(api, id)
    d = api.get("/v1/time-entries/#{id}")['Data']
    d.is_a?(Hash) ? d : nil
  rescue Gorelo::HttpError => e
    raise unless e.status == 404

    nil
  end

  # Returns [id, error].
  def resolve_work_type(api, ref)
    rows   = api.get_all('/v1/work-types')
    needle = ref.to_s.strip.downcase
    hit = rows.find { |r| r['Id'].to_s == needle } ||
          rows.find { |r| r['Name'].to_s.downcase == needle }
    return [hit, nil] if hit

    partial = rows.select { |r| r['Name'].to_s.downcase.include?(needle) }
    return [partial.first, nil] if partial.size == 1

    names = (partial.empty? ? rows : partial).map { |r| "#{r['Name']} (#{r['Id']})" }.join(', ')
    [nil, "#{partial.empty? ? 'No work type matches' : 'Several work types match'} #{ref.inspect}. " \
          "#{partial.empty? ? 'Available' : 'Candidates'}: #{names}"]
  end

  def resolve_billable_status(ref)
    s = ref.to_s.strip
    if s.match?(/\A\d+\z/)
      name = BILLABLE_STATUSES[s.to_i]
      return [{ 'Id' => s.to_i, 'Name' => name }, nil] if name
    else
      key = s.downcase.gsub(/[^a-z]/, '')
      key = 'nonbillable' if key == 'notbillable'
      hit = BILLABLE_STATUSES.find { |_, n| n.downcase.gsub(/[^a-z]/, '') == key }
      return [{ 'Id' => hit[0], 'Name' => hit[1] }, nil] if hit
    end
    [nil, "No billable status matches #{ref.inspect}. Available: " \
          "#{BILLABLE_STATUSES.map { |i, n| "#{n} (#{i})" }.join(', ')}"]
  end

  # Best effort: the name of a service line, so the preview shows more than an
  # id. Never blocks - Gorelo validates the id itself.
  def service_line_name(api, id)
    api.get_all('/v1/contracts').each do |c|
      Array(c['ServiceLines']).each do |sl|
        return "#{sl['Name']} (in contract group #{c['Name']})" if sl['Id'].to_s == id.to_s
      end
    end
    nil
  rescue Gorelo::Error
    nil
  end

  def appended(existing, line)
    return line if existing.to_s.strip.empty?
    return "#{existing}<p>#{CGI.escapeHTML(line)}</p>" if existing.match?(/<[a-z][^>]*>/i)

    "#{existing}\n#{line}"
  end

  def show_comment(text)
    s = text.to_s.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip
    s.empty? ? '(empty)' : clip(s, 70)
  end

  # Turns one request into { payload:, lines:, entry: } or { error: }.
  # `entry` is the freshly read row, so what is previewed is what is compared.
  def plan(api, args)
    unknown = args.keys.map(&:to_s) - FIELD_KEYS - CONTROL_KEYS
    unless unknown.empty?
      return { error: "Refused: #{unknown.join(', ')} cannot be changed here. Only #{FIELD_KEYS.join(', ')} " \
                      '(plus id, confirm, expected_updated_on) are accepted; hours, dates, user, ' \
                      'billing role and ticket are never writable through this server.' }
    end

    id = entry_id(args['id'])
    return { error: "Refused: id must be a time entry id (digits), got #{args['id'].inspect}." } unless id

    wanted = FIELD_KEYS.select { |k| args.key?(k) && !args[k].nil? }
    return { error: 'Nothing to do: give at least one of ' + FIELD_KEYS.join(', ') + '.' } if wanted.empty?
    if wanted.include?('comment') && wanted.include?('append_comment')
      return { error: 'Refused: give comment (replace) or append_comment (add a line), not both.' }
    end

    entry = fetch_entry(api, id)
    return { error: "No time entry #{id} found." } unless entry

    payload = {}
    lines   = []
    ticket  = entry['Ticket'] || {}

    if args.key?('work_type')
      wt, err = resolve_work_type(api, args['work_type'])
      return { error: "Time entry #{id}: #{err}" } if err

      cur = nested(entry, 'WorkType', 'Name')
      if nested(entry, 'WorkType', 'Id').to_s != wt['Id'].to_s
        payload['WorkTypeId'] = wt['Id']
        lines << "work type       #{cur || '(none)'} → #{wt['Name']}"
      end
    end

    if args.key?('billable_status')
      bs, err = resolve_billable_status(args['billable_status'])
      return { error: "Time entry #{id}: #{err}" } if err

      if nested(entry, 'BillableStatus', 'Id').to_s != bs['Id'].to_s
        payload['BillableStatusId'] = bs['Id']
        lines << "billable status #{nested(entry, 'BillableStatus', 'Name') || '(none)'} → #{bs['Name']}"
      end
    end

    if args.key?('service_line_id')
      sid = args['service_line_id'].to_s.strip
      return { error: "Time entry #{id}: service_line_id must be a number." } unless sid.match?(/\A\d+\z/)

      if nested(entry, 'ServiceLine', 'Id').to_s != sid
        payload['ServiceLineId'] = sid.to_i
        name = service_line_name(api, sid)
        cur  = nested(entry, 'ServiceLine', 'Name')
        lines << "service line    #{cur ? "#{cur} (#{nested(entry, 'ServiceLine', 'Id')})" : '(none)'} → " \
                 "#{sid}#{name ? " #{name}" : ' (not found in any contract group listing; Gorelo will validate it)'}"
      end
    end

    if args.key?('comment') || args.key?('append_comment')
      new_comment = args.key?('comment') ? args['comment'].to_s : appended(entry['Comment'], args['append_comment'].to_s.strip)
      if args.key?('append_comment') && args['append_comment'].to_s.strip.empty?
        return { error: "Time entry #{id}: append_comment is empty." }
      end

      if new_comment != entry['Comment'].to_s
        payload['Comment'] = new_comment
        lines << "comment         #{show_comment(entry['Comment'])} → #{show_comment(new_comment)}"
      end
    end

    { id: id, entry: entry, payload: payload, lines: lines, ticket: ticket }
  rescue Gorelo::Error => e
    { error: "Time entry #{args['id']}: #{e.message}" }
  end

  def header(p)
    e = p[:entry]
    t = p[:ticket]
    "Time entry #{p[:id]}  G-#{t['Number']}  #{clip(t['Title'], 60)}\n" \
      "  #{brisbane(e['StartedOn'])}  #{nested(e, 'User', 'Name')}  " \
      "#{format('%.2f', e['AdjustedHours'].to_f)}h adjusted (#{format('%.2f', e['ActualHours'].to_f)}h recorded)  " \
      "#{nested(e, 'BillableStatus', 'Name')} / #{nested(e, 'WorkType', 'Name')}"
  end

  def preview_text(p)
    out = [header(p)]
    if p[:payload].empty?
      out << '  No change: every requested value already matches. Nothing would be sent.'
    else
      p[:lines].each { |l| out << "  #{l}" }
      out << "  #{REPRICE_WARNING}"
    end
    out << "  expected_updated_on: #{p[:entry]['UpdatedOn'] || 'null'} (pass this back with confirm: true to refuse if the entry changed in between)"
    out.join("\n")
  end

  # Re-reads, checks the pin, PATCHes only the changed fields, prints the new
  # values. Returns [ok, text].
  def apply(api, args)
    p = plan(api, args)
    return [false, p[:error]] if p[:error]

    # An entry never updated has UpdatedOn null; the preview shows it as "null".
    pin = args['expected_updated_on']
    pin = '' if pin.to_s == 'null'
    if pin && pin.to_s != p[:entry]['UpdatedOn'].to_s
      return [false, "Refused: time entry #{p[:id]} has changed since the preview (UpdatedOn is " \
                     "#{p[:entry]['UpdatedOn'] || 'null'}, expected #{args['expected_updated_on']}). Nothing was written. " \
                     'Preview it again.']
    end
    return [true, "#{header(p)}\n  No change: every requested value already matches. Nothing was sent."] if p[:payload].empty?

    key = api.fingerprint(p[:id], p[:payload].to_json)
    begin
      resp = api.patch("/v1/time-entries/#{p[:id]}", p[:payload])
    rescue Gorelo::WritesDisabled => e
      return [false, e.message]
    rescue Gorelo::AmbiguousWrite => e
      api.record_write(key, "PATCH /v1/time-entries/#{p[:id]} #{p[:payload].to_json} → AMBIGUOUS")
      return [false, "⚠ Gorelo failed AFTER receiving the update for time entry #{p[:id]}, so it MAY have " \
                     "been applied. Read the entry before trying again.\n#{e.message}"]
    rescue Gorelo::Error => e
      return [false, "Gorelo refused the update to time entry #{p[:id]}: #{e.message}"]
    end

    after = resp['Data'].is_a?(Hash) ? resp['Data'] : nil
    after ||= begin
      fetch_entry(api, p[:id])
    rescue Gorelo::Error
      nil
    end
    unless after
      api.record_write(key, "PATCH /v1/time-entries/#{p[:id]} #{p[:payload].to_json} → applied (not read back)")
      return [false, "Sent the update to time entry #{p[:id]} but could NOT read it back. Check in Gorelo."]
    end

    failed = []
    failed << 'WorkTypeId'       if p[:payload].key?('WorkTypeId') && nested(after, 'WorkType', 'Id').to_s != p[:payload]['WorkTypeId'].to_s
    failed << 'BillableStatusId' if p[:payload].key?('BillableStatusId') && nested(after, 'BillableStatus', 'Id').to_s != p[:payload]['BillableStatusId'].to_s
    failed << 'ServiceLineId'    if p[:payload].key?('ServiceLineId') && nested(after, 'ServiceLine', 'Id').to_s != p[:payload]['ServiceLineId'].to_s
    failed << 'Comment'          if p[:payload].key?('Comment') && after['Comment'].to_s != p[:payload]['Comment']
    api.record_write(key, "PATCH /v1/time-entries/#{p[:id]} #{p[:payload].to_json} → " \
                          "#{failed.empty? ? 'applied' : "NO EFFECT on #{failed.join(',')}"}")

    out = ["Time entry #{p[:id]}  G-#{p[:ticket]['Number']}  #{clip(p[:ticket]['Title'], 60)}",
           failed.empty? ? '  Updated. New values as returned by Gorelo:' : "  ⚠ NOT APPLIED for: #{failed.join(', ')}. Values now:",
           "  #{format('%.2f', after['AdjustedHours'].to_f)}h adjusted (#{format('%.2f', after['ActualHours'].to_f)}h recorded)  " \
           "was #{format('%.2f', p[:entry]['AdjustedHours'].to_f)}h adjusted",
           "  billable status: #{nested(after, 'BillableStatus', 'Name')}",
           "  work type:       #{nested(after, 'WorkType', 'Name')}",
           "  service line:    #{nested(after, 'ServiceLine', 'Name') || '(none)'} (#{nested(after, 'ServiceLine', 'Id')})",
           "  comment:         #{show_comment(after['Comment'])}",
           "  UpdatedOn:       #{after['UpdatedOn'] || 'null'}"]
    [failed.empty?, out.join("\n")]
  end

  # One at a time, stopping at the first failure.
  def apply_batch(api, list, plans)
    done = []
    plans.each_with_index do |p, i|
      sleep(BATCH_DELAY) if i.positive?
      ok, text = apply(api, list[i])
      if ok
        done << p[:id]
        next
      end

      rest = list[(i + 1)..].map { |e| e['id'] }
      return ["STOPPED at entry #{p[:id]} (#{i + 1} of #{plans.size}). Applied before it: " \
              "#{done.empty? ? 'none' : done.join(', ')}.",
              "Not attempted: #{rest.empty? ? 'none' : rest.join(', ')}.", '', text].join("\n")
    end
    "Applied all #{done.size} entr#{done.size == 1 ? 'y' : 'ies'}: #{done.join(', ')}."
  end

  FIELD_PROPERTIES = {
    work_type:       { type: 'string', description: 'Work type name or id, e.g. "Peer Assist". Matched against gorelo_work_types.' },
    billable_status: { type: 'string', description: 'Billable, Non-billable, No charge or Void (or 1, 3, 2, 5).' },
    service_line_id: { type: 'integer', description: 'ServiceLine id (the UI calls it a Contract). See gorelo_list_contracts.' },
    comment:         { type: 'string', description: 'REPLACES the comment. Sent as given.' },
    append_comment:  { type: 'string', description: 'Adds a line after the existing comment.' }
  }.freeze

  # ---- tools ----------------------------------------------------------------

  def update_time_entry(server, api)
    server.tool(
      name:  'gorelo_update_time_entry',
      title: 'Recode one Gorelo time entry',
      description: <<~TEXT,
        Change how ONE time entry is billed: its work type, billable status, service line
        (the UI calls it a Contract) or comment. Nothing else is writable - not hours,
        dates, technician, billing role or ticket - and any other argument is refused.

        WITHOUT confirm: true this only PREVIEWS. It reads the entry and shows the ticket,
        the date (Brisbane time), the technician, the hours and current → new for each field.
        Nothing is written.

        WITH confirm: true it re-reads the entry, PATCHes only the fields that differ, and
        prints the values Gorelo returns. Pass expected_updated_on from the preview to refuse
        if anyone touched the entry in between.

        ⚠ Gorelo RE-PRICES the entry on a change of work type, billable status or service
        line, and moves contract hours between BlockHours / LimitedHours contracts. Entries
        already approved, completed, invoiced or void are refused by Gorelo (409).

        Disabled unless GORELO_ALLOW_WRITES=true. No delete path exists.
      TEXT
      read_only: false,
      input_schema: {
        type: 'object',
        properties: {
          id: { type: 'integer', description: 'The time entry id (see gorelo_list_time_entries).' },
          confirm: { type: 'boolean', description: 'Must be true to write. Absent or false previews only.' },
          expected_updated_on: { type: 'string', description: 'The UpdatedOn shown in the preview. With confirm, the write is refused if it no longer matches. Use "null" for an entry never updated.' }
        }.merge(FIELD_PROPERTIES),
        required: %w[id],
        additionalProperties: false
      }
    ) do |args|
      next 'Writes are disabled. Set GORELO_ALLOW_WRITES=true in .env and restart.' unless api.writes_allowed?

      if args['confirm'] == true
        _ok, text = apply(api, args)
        next text
      end

      p = plan(api, args)
      next p[:error] if p[:error]

      "PREVIEW ONLY - nothing was written.\n#{preview_text(p)}"
    end
  end

  def update_time_entries(server, api)
    server.tool(
      name:  'gorelo_update_time_entries',
      title: 'Recode several Gorelo time entries',
      description: <<~TEXT,
        The batch form of gorelo_update_time_entry: up to #{MAX_BATCH} entries, each with the
        same allowed fields (work_type, billable_status, service_line_id, comment,
        append_comment) and an optional expected_updated_on.

        WITHOUT confirm: true it previews every entry and writes nothing. If ANY entry is
        invalid the whole batch is refused and every problem is listed.

        WITH confirm: true it applies the entries one at a time, about one request per second
        each, STOPS AT THE FIRST ERROR and says exactly what was applied and what was not.
        Gorelo RE-PRICES each entry it changes.

        Disabled unless GORELO_ALLOW_WRITES=true.
      TEXT
      read_only: false,
      input_schema: {
        type: 'object',
        properties: {
          entries: {
            type: 'array', minItems: 1, maxItems: MAX_BATCH,
            items: {
              type: 'object',
              properties: { id: { type: 'integer' },
                            expected_updated_on: { type: 'string' } }.merge(FIELD_PROPERTIES),
              required: %w[id],
              additionalProperties: false
            }
          },
          confirm: { type: 'boolean', description: 'Must be true to write. Absent or false previews only.' }
        },
        required: %w[entries],
        additionalProperties: false
      }
    ) do |args|
      next 'Writes are disabled. Set GORELO_ALLOW_WRITES=true in .env and restart.' unless api.writes_allowed?

      list = args['entries']
      next 'Refused: entries must be a non-empty list.' unless list.is_a?(Array) && !list.empty?
      next "Refused: at most #{MAX_BATCH} entries per call." if list.size > MAX_BATCH
      next 'Refused: every entry must be an object with an id.' unless list.all? { |e| e.is_a?(Hash) }
      next 'Refused: confirm is a top-level argument, not a per-entry one.' if list.any? { |e| e.key?('confirm') }

      ids = list.map { |e| entry_id(e['id']) }
      dup = ids.compact.tally.select { |_, n| n > 1 }.keys
      next "Refused: duplicate ids in the batch: #{dup.join(', ')}." unless dup.empty?

      plans = list.map { |e| plan(api, e) }
      bad   = plans.select { |p| p[:error] }
      unless bad.empty?
        next "Refused - nothing was written. #{bad.size} of #{plans.size} entries have a problem:\n" +
             bad.map { |p| "  #{p[:error]}" }.join("\n")
      end

      unless args['confirm'] == true
        out = ["PREVIEW ONLY - nothing was written. #{plans.size} entr#{plans.size == 1 ? 'y' : 'ies'}.", '']
        plans.each { |p| out << preview_text(p) << '' }
        changing = plans.count { |p| !p[:payload].empty? }
        out << "#{changing} would change, #{plans.size - changing} already match. #{REPRICE_WARNING}"
        next out.join("\n")
      end

      apply_batch(api, list, plans)
    end
  end
end
