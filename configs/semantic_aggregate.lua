-- Pipeline B: EDGE (collector-side) semantic aggregation.
--
-- Collapses records that share a normalized template signature into a single
-- document, carrying a cumulative `count`. To get real edge volume reduction
-- it forwards far fewer records than it receives: it emits the first sighting
-- of a signature, then re-emits the running count only when it has grown by a
-- bounded fraction (EMIT_EPS). The destination upserts by `_agg_id`, so the
-- stored count is the last forwarded value.
--
-- Bounded information loss (the whole point of the B-vs-C trade-off):
--   * Normal completion: stored count trails the true count by <= EMIT_EPS,
--     because the tail of each signature is not re-emitted. IPR ~ 1 - EMIT_EPS.
--   * Collector crash: the unforwarded tail (also <= EMIT_EPS per live
--     signature) plus anything in flight is lost. This is measured, not assumed.
--
-- EMIT_EPS is read from the FB_EMIT_EPS env var (default 0.02 => ~2% loss).

local buffer = {}
local EMIT_EPS = tonumber(os.getenv("FB_EMIT_EPS") or "0.02")

local function normalize(message)
    -- Order matters: UUID and IP must run before the generic %d+ rule,
    -- otherwise %d+ shreds them first and the specific rules never match.
    local t = message
    t = string.gsub(t, "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x", "{UUID}")
    t = string.gsub(t, "%d+%.%d+%.%d+%.%d+", "{IP}")
    t = string.gsub(t, "%d+", "{NUM}")
    t = string.gsub(t, "\"[^\"]*\"", "{STR}")
    return t
end

-- Fields arrive flattened with a `log_` prefix (see the nest/lift filters),
-- so read both the bare and prefixed names.
local function field(record, key)
    return record[key] or record["log_" .. key]
end

local function signature(record)
    local msg = field(record, "message") or ""
    local level = field(record, "level") or "INFO"
    local component = field(record, "component") or "unknown"
    return level .. "|" .. component .. "|" .. normalize(msg)
end

local function tag_record(record, sig, count)
    record["_agg_id"] = sig
    record["_agg_signature"] = sig
    record["count"] = count
    record["aggregated"] = true
    return record
end

function cb_dedup(tag, timestamp, record)
    local sig = signature(record)
    local entry = buffer[sig]

    if not entry then
        buffer[sig] = { count = 1, last_emit = 1 }
        return 1, timestamp, tag_record(record, sig, 1)
    end

    entry.count = entry.count + 1
    if entry.count >= entry.last_emit * (1 + EMIT_EPS) then
        entry.last_emit = entry.count
        return 1, timestamp, tag_record(record, sig, entry.count)
    end

    -- Duplicate within the current emit window: drop it (edge reduction).
    return -1, 0, 0
end
