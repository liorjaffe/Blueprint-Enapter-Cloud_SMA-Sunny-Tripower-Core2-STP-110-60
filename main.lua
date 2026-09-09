-- SMA Sunny Tripower CORE2 STP110-60
-- Read-only SunSpec Modbus TCP integration for an Enapter Virtual UCM.
-- Change DEVICE_HOST before uploading the blueprint.

local DEVICE_HOST = "xxx.xxx.xxx.xx"
local DEVICE_PORT = 502
local UNIT_ID = 1

local READ_START_FALLBACK = 0
local READ_COUNT = 125
local TIMEOUT_MS = 1000
local RATED_POWER_W = 110000

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
  local new_client
  local err

  if ok_modbus and modbus and modbus.new then
    new_client, err = modbus.new(uri)
    if new_client then
      backend = "modbus"
      return new_client
    end
    last_error = "modbus.new failed: " .. tostring(err)
  end

  if ok_modbustcp and modbustcp and modbustcp.new then
    new_client = modbustcp.new(DEVICE_HOST .. ":" .. tostring(DEVICE_PORT))
    if new_client then
      backend = "modbustcp"
      return new_client
    end
    last_error = "modbustcp.new failed"
  end

  if not ok_modbus and not ok_modbustcp then
    last_error = "Neither modbus nor modbustcp is available"
  end

  backend = nil
  return nil
end

local function read_registers(kind, start_register, count, unit_id)
  if not client then
    return nil, "no client"
  end

  local values
  local result

  if kind == "inputs" then
    values, result = client:read_inputs(unit_id or active_unit_id, start_register, count, TIMEOUT_MS)
  else
    values, result = client:read_holdings(unit_id or active_unit_id, start_register, count, TIMEOUT_MS)
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

local function discover_layout()
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
      local header, err = read_registers(probe.kind, probe.start, 2, unit_id)
      if header and is_sunspec_header(header) then
        probe.unit_id = unit_id
        return probe, nil
      end
      errors[#errors + 1] = probe.kind .. ":" .. tostring(probe.start)
        .. "/unit:" .. tostring(unit_id) .. "=" .. error_text(err)
    end
  end

  return nil, table.concat(errors, ", ")
end

local function reconnect()
  if client then
    return true
  end

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
  last_error = nil
  enapter.log(
    "SunSpec connection ready, " .. layout.kind .. " at register " .. tostring(layout.start)
      .. " with Unit ID " .. tostring(layout.unit_id),
    "info"
  )
  return true
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

local function send_telemetry()
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

-- device/1.0 blueprints use top-level scheduler registration.
scheduler.add(1000, reconnect)
scheduler.add(5000, send_telemetry)
scheduler.add(30000, send_properties)

send_properties()
