-- SMA Sunny Tripower CORE2 STP110-60
-- Read-only SunSpec Modbus TCP integration for an Enapter Virtual UCM.
-- Change DEVICE_HOST before uploading the blueprint.

local DEVICE_HOST = "xxx.xxx.xxx.xxx"
local DEVICE_PORT = 502
local UNIT_ID = 1

local READ_START_FALLBACK = 0
local READ_COUNT = 125
local TIMEOUT_MS = 1000
local DISCOVERY_TIMEOUT_MS = 300 -- shorter timeout used only while probing for
                                  -- the register layout, so a full 24-combo
                                  -- scan can never exceed the scheduler's
                                  -- 10 second per-call execution limit.
local RATED_POWER_W = 110000

-- Reconnect attempts back off exponentially instead of retrying every
-- second. Retrying too fast while the inverter is unreachable was leaving
-- unclosed Modbus TCP sockets piling up (the modbustcp API has no close()
-- call, only garbage collection), which is very likely what has been
-- exhausting the SMA's small limit of concurrent Modbus TCP connections
-- and requiring a full device reboot to clear.
local RECONNECT_BACKOFF_INITIAL_S = 2
local RECONNECT_BACKOFF_MAX_S = 30

local function load_api(name)
  -- Current Enapter runtimes expose protocol APIs as globals. Older runtimes
  -- may expose the same API through require(), so support both forms.
  local global_api = rawget(_G, name)
  if global_api then
    return true, global_api
  end

  local ok, required_api = pcall(require, name)
  if ok and required_api then
    return true, required_api
  end
  return false, nil
end

local ok_modbus, modbus = load_api("modbus")
local ok_modbustcp, modbustcp = load_api("modbustcp")

local client = nil
local backend = nil
local layout = nil
local active_unit_id = UNIT_ID
local last_error = nil

-- Remembers the register kind/start/unit ID that worked last time, so a
-- reconnect after a brief network blip only needs to re-check that single
-- combination instead of scanning every possibility again.
local last_known_layout = nil

local reconnect_backoff_s = RECONNECT_BACKOFF_INITIAL_S
local next_reconnect_at_s = 0

local function error_text(value)
  if value == nil then
    return "no error code returned"
  end

  if backend == "modbustcp" and modbustcp and modbustcp.err_to_str
      and type(value) == "number" then
    local ok, text = pcall(modbustcp.err_to_str, value)
    if ok and text then
      return tostring(value) .. " (" .. tostring(text) .. ")"
    end
  end

  return tostring(value)
end

local function create_client()
  local uri = "tcp://" .. DEVICE_HOST .. ":" .. tostring(DEVICE_PORT)

  if ok_modbus and modbus and modbus.new then
    local ok, new_client, err = pcall(modbus.new, uri)
    if ok and new_client then
      backend = "modbus"
      return new_client
    end
    last_error = "modbus.new failed: " .. tostring(ok and err or new_client)
  end

  if ok_modbustcp and modbustcp and modbustcp.new then
    local ok, new_client = pcall(modbustcp.new, DEVICE_HOST .. ":" .. tostring(DEVICE_PORT))
    if ok and new_client then
      backend = "modbustcp"
      return new_client
    end
    last_error = "modbustcp.new failed: " .. tostring(ok and "no client returned" or new_client)
  end

  if not ok_modbus and not ok_modbustcp then
    last_error = "Neither modbus nor modbustcp is available"
  end

  backend = nil
  return nil
end

local function read_registers(kind, start_register, count, unit_id, timeout_ms)
  if not client then
    return nil, "no client"
  end

  local resolved_timeout = timeout_ms or TIMEOUT_MS
  local resolved_unit_id = unit_id or active_unit_id

  -- pcall protects against the Modbus binding raising a Lua error (e.g. on
  -- a broken/reset socket) instead of returning an error value. Without
  -- this, such an error would propagate out of reconnect()/send_telemetry()
  -- uncaught and could permanently stop the scheduled jobs from running
  -- again until the device was rebooted.
  local ok, values, result
  if kind == "inputs" then
    ok, values, result = pcall(function()
      return client:read_inputs(resolved_unit_id, start_register, count, resolved_timeout)
    end)
  else
    ok, values, result = pcall(function()
      return client:read_holdings(resolved_unit_id, start_register, count, resolved_timeout)
    end)
  end

  if not ok then
    return nil, "exception: " .. tostring(values)
  end

  if not values then
    return nil, result
  end

  -- modbus.new returns nil on success; modbustcp returns numeric 0 on success.
  if backend == "modbustcp" and result ~= nil and result ~= 0 then
    return nil, result
  end
  if backend == "modbus" and result ~= nil then
    return nil, result
  end

  return values, nil
end

local function is_sunspec_header(data)
  if not data or #data < 2 then
    return false
  end

  -- Enapter's Modbus API returns registers in normalized byte order.
  return data[1] == 0x5375 and data[2] == 0x6E53
end

local function probe_combo(kind, start, unit_id)
  local header, err = read_registers(kind, start, 2, unit_id, DISCOVERY_TIMEOUT_MS)
  if header and is_sunspec_header(header) then
    return { kind = kind, start = start, unit_id = unit_id }
  end
  return nil, err
end

local function discover_layout()
  -- Fast path: retry the combination that worked last time first. This
  -- keeps a routine reconnect to a single request and comfortably within
  -- the scheduler's 10 second per-call execution limit.
  if last_known_layout then
    local found = probe_combo(last_known_layout.kind, last_known_layout.start, last_known_layout.unit_id)
    if found then
      return found, nil
    end
  end

  -- SMA installations differ in register type, register base and Unit ID.
  -- Probe only the two-register SunSpec header, then retain the successful
  -- combination for all following reads.
  local probes = {
    { kind = "holdings", start = READ_START_FALLBACK },
    { kind = "inputs", start = READ_START_FALLBACK },
    { kind = "holdings", start = 40000 },
    { kind = "inputs", start = 40000 },
    { kind = "holdings", start = 40001 },
    { kind = "inputs", start = 40001 },
  }
  local unit_ids = { UNIT_ID, 3, 2, 4 }
  local errors = {}

  for _, unit_id in ipairs(unit_ids) do
    for _, probe in ipairs(probes) do
      local found, err = probe_combo(probe.kind, probe.start, unit_id)
      if found then
        return found, nil
      end
      errors[#errors + 1] = probe.kind .. ":" .. tostring(probe.start)
        .. "/unit:" .. tostring(unit_id) .. "=" .. error_text(err)
    end
  end

  return nil, table.concat(errors, ", ")
end

local function attempt_reconnect()
  if not ok_modbus and not ok_modbustcp then
    if last_error ~= "Neither modbus nor modbustcp is available" then
      last_error = "Neither modbus nor modbustcp is available"
      enapter.log(last_error, "error", true)
    end
    return false
  end

  client = create_client()
  if not client then
    if last_error then
      enapter.log(last_error, "error")
    end
    return false
  end

  local discovered_layout, probe_error = discover_layout()
  layout = discovered_layout
  if not layout then
    last_error = "SunSpec header not found. Probe results: " .. tostring(probe_error)
    enapter.log(last_error, "error", true)
    client = nil
    backend = nil
    active_unit_id = UNIT_ID
    return false
  end

  active_unit_id = layout.unit_id
  last_known_layout = { kind = layout.kind, start = layout.start, unit_id = layout.unit_id }
  last_error = nil
  enapter.log(
    "SunSpec connection ready, " .. layout.kind .. " at register " .. tostring(layout.start)
      .. " with Unit ID " .. tostring(layout.unit_id),
    "info"
  )
  return true
end

-- force = true bypasses the backoff timer and forces a fresh connection
-- even if `client` currently looks alive. Used by the manual "Reconnect"
-- command below.
local function reconnect(force)
  if client and not force then
    return true
  end

  local now = system.uptime()
  if not force and now < next_reconnect_at_s then
    return false
  end

  if force and client then
    client = nil
    backend = nil
    layout = nil
  end

  -- pcall here is the final safety net: even if something inside
  -- attempt_reconnect() raises an unexpected Lua error, it is caught here
  -- and treated as a failed attempt (with backoff) instead of killing the
  -- scheduled job that called reconnect().
  local ok, result = pcall(attempt_reconnect)
  local success = ok and result

  if not ok then
    last_error = "reconnect() raised an error: " .. tostring(result)
    enapter.log(last_error, "error", true)
    client = nil
    backend = nil
    layout = nil
  end

  if success then
    reconnect_backoff_s = RECONNECT_BACKOFF_INITIAL_S
    next_reconnect_at_s = 0
    return true
  end

  -- Encourage prompt collection of the abandoned client/socket object
  -- before the next attempt, since the Modbus TCP API has no explicit
  -- close() call.
  collectgarbage("collect")
  next_reconnect_at_s = now + reconnect_backoff_s
  reconnect_backoff_s = math.min(reconnect_backoff_s * 2, RECONNECT_BACKOFF_MAX_S)
  return false
end

local function pow10(value)
  return 10 ^ value
end

local function to_i16(value)
  if value >= 32768 then
    return value - 65536
  end
  return value
end

local function scaled_u16(value, scale_factor)
  if value == nil or scale_factor == nil or value == 65535 then
    return nil
  end
  return value * pow10(scale_factor)
end

local function scaled_i16(value, scale_factor)
  if value == nil or scale_factor == nil or value == 32768 then
    return nil
  end
  return to_i16(value) * pow10(scale_factor)
end

local function u32_from_registers(msw, lsw)
  if msw == nil or lsw == nil then
    return nil
  end
  if msw == 65535 and lsw == 65535 then
    return nil
  end
  return msw * 65536 + lsw
end

local function scan_sunspec_models(data)
  local models = {}
  if not is_sunspec_header(data) then
    return models
  end

  local index = 3
  while index + 1 <= #data do
    local model_id = data[index]
    local model_length = data[index + 1]

    if model_id == nil or model_length == nil then
      break
    end
    if model_id == 0xFFFF then
      break
    end
    if model_length <= 0 then
      break
    end

    local payload_start = index + 2
    local payload_end = payload_start + model_length - 1
    if payload_end > #data then
      break
    end

    models[model_id] = {
      start = payload_start,
      length = model_length,
    }
    index = payload_end + 1
  end

  return models
end

local function parse_model_103(data, payload_start, model_length)
  -- SunSpec model 103 payload offsets are zero-based. The payload begins at
  -- payload_start in Lua's one-based array.
  if not model_length or model_length < 37 then
    return nil
  end

  local t = {}
  local p = payload_start

  local a_sf = to_i16(data[p + 4])
  local v_sf = to_i16(data[p + 11])
  local w_sf = to_i16(data[p + 13])
  local hz_sf = to_i16(data[p + 15])
  local va_sf = to_i16(data[p + 17])
  local var_sf = to_i16(data[p + 19])
  local pf_sf = to_i16(data[p + 21])
  local wh_sf = to_i16(data[p + 24])
  local dca_sf = to_i16(data[p + 26])
  local dcv_sf = to_i16(data[p + 28])
  local dcw_sf = to_i16(data[p + 30])
  local tmp_sf = to_i16(data[p + 35])

  t.ac_l1_current = scaled_u16(data[p + 1], a_sf)
  t.ac_l2_current = scaled_u16(data[p + 2], a_sf)
  t.ac_l3_current = scaled_u16(data[p + 3], a_sf)

  -- Model 103 provides phase-to-neutral voltages at offsets 8, 9 and 10.
  t.ac_l1_voltage = scaled_u16(data[p + 8], v_sf)
  t.ac_l2_voltage = scaled_u16(data[p + 9], v_sf)
  t.ac_l3_voltage = scaled_u16(data[p + 10], v_sf)

  local total_power = scaled_i16(data[p + 12], w_sf)
  t.ac_total_power = total_power
  if total_power ~= nil then
    t.ac_total_power_kw = total_power / 1000
    -- Model 103 has total AC power only. These are estimates, not phase values.
    t.ac_l1_power = total_power / 3
    t.ac_l2_power = total_power / 3
    t.ac_l3_power = total_power / 3
  end

  t.ac_frequency = scaled_u16(data[p + 14], hz_sf)
  t.ac_power_apparent = scaled_i16(data[p + 16], va_sf)
  t.ac_power_reactive = scaled_i16(data[p + 18], var_sf)
  t.ac_power_factor = scaled_i16(data[p + 20], pf_sf)

  local energy_raw = u32_from_registers(data[p + 22], data[p + 23])
  if energy_raw ~= nil then
    local energy_wh = energy_raw * pow10(wh_sf)
    t.ac_energy_total = energy_wh
    t.ac_energy_total_kwh = energy_wh / 1000
  end

  t.dc_current = scaled_u16(data[p + 25], dca_sf)
  t.dc_voltage = scaled_u16(data[p + 27], dcv_sf)
  t.dc_power = scaled_i16(data[p + 29], dcw_sf)

  local sink_temperature = scaled_i16(data[p + 32], tmp_sf)
  local cabinet_temperature = scaled_i16(data[p + 31], tmp_sf)
  t.inverter_temperature = sink_temperature or cabinet_temperature
  t.sun_spec_status = data[p + 36]

  return t
end

local function map_status(status)
  if status == 4 then
    return "running"
  elseif status == 5 then
    return "throttled"
  elseif status == 3 then
    return "starting"
  elseif status == 7 then
    return "error"
  elseif status == 1 or status == 2 or status == 6 or status == 8 then
    return "idle"
  end
  return "error"
end

local function send_properties()
  enapter.send_properties({
    inverter_nameplate_capacity = RATED_POWER_W,
  })
end

local function send_error_telemetry(alert_name)
  enapter.send_telemetry({
    status = "error",
    alerts = { alert_name },
  })
end

local function send_telemetry_impl()
  if not client or not layout then
    if not reconnect() or not layout then
      send_error_telemetry("communication_failed")
      return
    end
  end

  local data, err = read_registers(layout.kind, layout.start, READ_COUNT, layout.unit_id)
  if not data then
    local message = "SunSpec read failed: " .. error_text(err)
    if message ~= last_error then
      enapter.log(message, "error", true)
      last_error = message
    end
    client = nil
    backend = nil
    layout = nil
    send_error_telemetry("communication_failed")
    return
  end

  local models = scan_sunspec_models(data)
  local model = models[103]
  if not model then
    enapter.log("SunSpec model 103 was not found", "error")
    enapter.send_telemetry({
      status = "error",
      sun_spec_model = 103,
      alerts = { "unsupported_device" },
    })
    return
  end

  local telemetry = parse_model_103(data, model.start, model.length)
  if not telemetry then
    enapter.log("SunSpec model 103 payload is shorter than required", "error")
    send_error_telemetry("unsupported_device")
    return
  end

  telemetry.sun_spec_model = 103
  telemetry.status = map_status(telemetry.sun_spec_status)
  telemetry.sun_spec_status = nil
  telemetry.alerts = {}
  enapter.send_telemetry(telemetry)
end

local function send_telemetry()
  -- Final safety net: if anything above raises an unexpected Lua error
  -- (e.g. unexpectedly malformed register data), catch it here instead of
  -- letting it kill this scheduled job for good.
  local ok, err = pcall(send_telemetry_impl)
  if not ok then
    local message = "send_telemetry exception: " .. tostring(err)
    if message ~= last_error then
      enapter.log(message, "error", true)
      last_error = message
    end
    client = nil
    backend = nil
    layout = nil
    send_error_telemetry("communication_failed")
  end
end

-- Manual "Reconnect" command, exposed as a quick-access button in the
-- Enapter app. There is no way for a Virtual UCM Lua script to power-cycle
-- itself (no system.reboot() exists in the Lua API), so this instead does
-- what a manual device reboot has actually been fixing: it drops the
-- current connection, garbage-collects it, and immediately re-establishes
-- it, bypassing the normal backoff timer.
local function reconnect_command(ctx, args)
  ctx.log("Manual reconnect requested from the Enapter app", "info")
  local success = reconnect(true)
  if success then
    ctx.log("Reconnected successfully", "info")
    return { status = "reconnected" }
  end
  ctx.error("Reconnect failed: " .. tostring(last_error))
end

enapter.register_command_handler("reconnect", reconnect_command)

-- device/1.0 blueprints use top-level scheduler registration.
scheduler.add(1000, reconnect)
scheduler.add(5000, send_telemetry)
scheduler.add(30000, send_properties)

send_properties()

