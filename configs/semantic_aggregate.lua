local aggregation_buffer = {}
local buffer_count = 0
local MAX_BUFFER = 10000

function extract_template(message)
    local template = string.gsub(message, "%d+", "{NUM}")
    template = string.gsub(template, "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x", "{UUID}")
    template = string.gsub(template, "%d+%.%d+%.%d+%.%d+", "{IP}")
    template = string.gsub(template, "\"[^\"]*\"", "{STR}")
    template = string.gsub(template, "/[%w/-]+", "{PATH}")
    return template
end

function generate_signature(record)
    local msg = record["message"] or record["log_message"] or ""
    local template = extract_template(msg)
    local level = record["level"] or "INFO"
    local component = record["component"] or "unknown"
    return level .. "|" .. component .. "|" .. template
end

function cb_dedup(tag, timestamp, record)
    local sig = generate_signature(record)
    if aggregation_buffer[sig] then
        return -1, 0, 0
    else
        aggregation_buffer[sig] = { timestamp = timestamp, count = 1 }
        buffer_count = buffer_count + 1
        if buffer_count > MAX_BUFFER then
            aggregation_buffer = {}
            buffer_count = 0
        end
        return 1, timestamp, record
    end
end
