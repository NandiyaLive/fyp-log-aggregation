-- Pipeline C: INDEX-TIME aggregation.
--
-- Forwards EVERY record (no edge reduction, higher ingest cost) but assigns
-- each a deterministic document id equal to its normalized template signature
-- and carries a cumulative `count`. The destination upserts by `_agg_id`, so
-- the index collapses to one document per signature and the stored count
-- converges to the true total.
--
-- Because every occurrence is forwarded, the last record for each signature
-- always carries the full count, so there is no normal-path information loss
-- and the in-flight window exposed to a crash is minimal (zero-loss target).
--
-- The normalization MUST be byte-for-byte identical to semantic_aggregate.lua
-- so that B and C deduplicate on the same key and are directly comparable.

local counts = {}

local function normalize(message)
    local t = message
    t = string.gsub(t, "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x", "{UUID}")
    t = string.gsub(t, "%d+%.%d+%.%d+%.%d+", "{IP}")
    t = string.gsub(t, "%d+", "{NUM}")
    t = string.gsub(t, "\"[^\"]*\"", "{STR}")
    return t
end

local function field(record, key)
    return record[key] or record["log_" .. key]
end

local function signature(record)
    local msg = field(record, "message") or ""
    local level = field(record, "level") or "INFO"
    local component = field(record, "component") or "unknown"
    return level .. "|" .. component .. "|" .. normalize(msg)
end

function cb_generate_id(tag, timestamp, record)
    local sig = signature(record)
    local c = (counts[sig] or 0) + 1
    counts[sig] = c
    record["_agg_id"] = sig
    record["_agg_signature"] = sig
    record["count"] = c
    record["aggregated"] = true
    return 1, timestamp, record
end
