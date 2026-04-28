function cb_generate_id(tag, timestamp, record)
    local msg = record["message"] or record["log_message"] or ""
    msg = string.gsub(msg, "%d+", "{NUM}")
    msg = string.gsub(msg, "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x", "{UUID}")
    msg = string.gsub(msg, "%d+%.%d+%.%d+%.%d+", "{IP}")
    local level = record["level"] or "INFO"
    local component = record["component"] or "unknown"
    local sig = level .. "|" .. component .. "|" .. msg
    record["_agg_id"] = sig
    record["_agg_signature"] = sig
    return 1, timestamp, record
end
