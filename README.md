# SMA Sunny Tripower CORE2 STP110-60

Enapter Blueprint for read-only monitoring of an SMA Sunny Tripower CORE2 STP110-60 via SunSpec Modbus TCP.

## Status

The blueprint was successfully tested on an Enapter Virtual UCM on September 9, 2026. The inverter was detected and continuously provided live telemetry data. The successful connection log reported:

```text
SunSpec connection ready, holdings at register 40000 with Unit ID 1
```

The following telemetry was received continuously:

- Device status
- Real-time AC active power
- Reactive power
- Apparent power
- Power factor
- AC voltages
- AC currents
- DC voltage
- DC current
- DC power
- Cumulative energy yield
- Inverter temperature

## Files

The blueprint consists of two main files:

```text
manifest.yml
main.lua
```

`manifest.yml` defines the device metadata, properties, telemetry fields, and alerts.

`main.lua` implements the SunSpec Modbus TCP communication and data parsing.

## Requirements

- An Enapter Gateway with a Virtual UCM.
- An SMA Sunny Tripower CORE2 reachable via Ethernet.
- TCP port 502 reachable between the Enapter Gateway and the inverter.
- SunSpec Modbus TCP enabled on the SMA inverter.
- The current `main.lua` file from this project.

An Enapter Virtual UCM runs as software on the Enapter Gateway and is designed for Ethernet and Modbus TCP devices.

## Connection configuration

The connection is configured in `main.lua`:

```lua
local DEVICE_HOST = "192.168.1.123"
local DEVICE_PORT = 502
local UNIT_ID = 1
```

`DEVICE_HOST` must be the IP address that is reachable from the Enapter Gateway.

If the Gateway and the inverter are in the same local network, use the local IP address of the SMA inverter. A public router address should only be used when a VPN or a correctly configured port forwarding solution is available.


The tested inverter responded with:

```text
Register type: holdings
Start address: 40000
Unit ID: 1
```

The software also probes additional combinations in case the register mapping differs between installations.

## Manifest

The project intentionally uses the older Blueprint specification accepted by the target system:

```yaml
blueprint_spec: device/1.0

communication_module:
  product: ENP-VIRTUAL
  lua_file: main.lua
```

The `runtime`, `requirements`, `options`, and newer `configuration` sections are not used in this project because the target validator accepts `device/1.0`.

## Automatic connection discovery

When the script starts, `main.lua` performs the following steps:

1. It loads the Modbus API provided by the Enapter runtime.
2. It supports both the current direct API and older module-based loading.
3. It probes the two-register SunSpec header.
4. It tests holding registers and input registers.
5. It tests register start addresses `0`, `40000`, and `40001`.
6. It tests Unit IDs `1`, `3`, `2`, and `4`.
7. After finding a valid SunSpec header, it keeps the successful combination for all following reads.
8. It scans the SunSpec model chain.
9. It parses SunSpec inverter model 103.

The tested device was detected using holding registers starting at address `40000` with Unit ID `1`.

## Main measured values

The following fields are measured values read from SunSpec model 103:

| Field | Meaning |
|---|---|
| `ac_total_power` | Measured total AC active power in watts |
| `ac_total_power_kw` | The same measured total AC active power converted to kilowatts |
| `ac_power_apparent` | Total apparent power |
| `ac_power_reactive` | Total reactive power |
| `ac_power_factor` | Total power factor |
| `ac_frequency` | Grid frequency |
| `ac_l1_voltage` | AC voltage from L1 to neutral |
| `ac_l2_voltage` | AC voltage from L2 to neutral |
| `ac_l3_voltage` | AC voltage from L3 to neutral |
| `ac_l1_current` | AC current on L1 |
| `ac_l2_current` | AC current on L2 |
| `ac_l3_current` | AC current on L3 |
| `dc_voltage` | DC voltage |
| `dc_current` | DC current |
| `dc_power` | DC power |
| `inverter_temperature` | Heat sink temperature, or cabinet temperature as fallback |
| `status` | Normalized inverter operating status |
| `sun_spec_model` | Detected SunSpec model number |

The value shown as `Real-time Active Power` in the Enapter application is based on the measured SunSpec total active power field `W`.

For example:

```text
Real-time Active Power: 39.33 kW
```

The field `ac_total_power_kw` is calculated only by converting watts to kilowatts:

```lua
ac_total_power_kw = ac_total_power / 1000
```

No phase balancing assumption is used for this value.

## Energy yield

The blueprint provides the cumulative energy counter from SunSpec field `WH`:

```text
ac_energy_total
```

The same value is also provided in kilowatt-hours:

```text
ac_energy_total_kwh
```

The Enapter application can therefore display a value such as:

```text
Total Yield: 124914.5 kWh
```

This is the cumulative energy value reported by the inverter.

A separate daily yield value is not currently read from SunSpec model 103. A daily value would require either:

- A dedicated SMA register.
- An extended SunSpec model.
- A persistent midnight baseline calculation.

## Estimated phase active power

SunSpec model 103 provides:

- Total AC active power.
- Phase currents.
- Phase voltages.

It does not provide independent measured active power values for L1, L2, and L3.

For this reason, the following fields are estimates:

```text
Estimated AC Active Power L1
Estimated AC Active Power L2
Estimated AC Active Power L3
```

They are calculated as:

```text
Estimated AC Active Power L1 = Total AC Active Power / 3
Estimated AC Active Power L2 = Total AC Active Power / 3
Estimated AC Active Power L3 = Total AC Active Power / 3
```

For example, if the measured total active power is `36.9 kW`, the application shows approximately:

```text
L1: 12.3 kW
L2: 12.3 kW
L3: 12.3 kW
```

These values are not independent phase measurements. They must not be used for phase imbalance analysis.

The authoritative value for the inverter output is:

```text
ac_total_power
```

or:

```text
ac_total_power_kw
```

Do not compare only L1 plus L2 with total active power. A three-phase total includes L1, L2, and L3.

## Why voltage and current do not provide exact phase active power

The approximate phase apparent power can be calculated from voltage and current:

```text
Phase apparent power = Phase voltage × Phase current
```

However, exact active power also requires the individual phase power factor and phase angle.

Because SunSpec model 103 does not provide separate phase power factors, the exact active power of each phase cannot be calculated reliably from the available data.

## Status mapping

SunSpec operating states are mapped to the Blueprint status field as follows:

| SunSpec `St` | Blueprint status |
|---:|---|
| 1, 2, 6, 8 | `idle` |
| 3 | `starting` |
| 4 | `running` |
| 5 | `throttled` |
| 7 | `error` |

The status `running` indicates that the inverter is operating normally according to its SunSpec operating state.

## Alerts

The Blueprint defines the following alerts:

- `communication_failed`: Modbus communication or telemetry reading failed.
- `unsupported_device`: No supported SunSpec three-phase inverter model 103 was found.
- `not_configured`: The connection has not been configured.

The `alerts` array is empty when no alert is active.

## Telemetry intervals

The Blueprint sends:

- Telemetry approximately every 5 seconds.
- Device properties approximately every 30 seconds.

The frequent telemetry log entries are therefore expected during normal operation.

## Error handling

The script handles the following conditions:

- Missing Modbus APIs.
- Failed Modbus reads.
- Missing or invalid SunSpec headers.
- Unsupported SunSpec model chains.
- Missing numeric error codes.
- Missing SunSpec layout information.
- Temporary communication failures.

When communication fails, the script:

1. Logs the error.
2. Resets the Modbus client.
3. Clears the detected layout.
4. Sends a communication alert.
5. Attempts to reconnect during the next scheduled cycle.

## Expected successful log output

A successful connection should produce a log entry similar to:

```text
SunSpec connection ready, holdings at register 40000 with Unit ID 1
```

The following telemetry confirms that the inverter is being read:

```text
status: running
sun_spec_model: 103
ac_total_power_kw: ...
ac_energy_total_kwh: ...
```

## Troubleshooting

### The Modbus API is not available

If the log reports:

```text
Neither modbus nor modbustcp is available
```

check that:

- The Blueprint is assigned to a Virtual UCM.
- The Virtual UCM is running on the intended Gateway.
- The Gateway software is operational.
- The latest `main.lua` is being uploaded.

### The SunSpec header cannot be found

If the log reports:

```text
SunSpec header not found. Probe results: ...
```

check:

- The inverter IP address.
- TCP port 502.
- The network route between the Gateway and the inverter.
- Whether Modbus TCP is enabled on the SMA.
- The Unit ID.
- Whether the Gateway can reach the inverter directly.

### The device uploads successfully but no telemetry appears

A successful upload only confirms that the Blueprint was transferred successfully. It does not confirm that the inverter responded to Modbus requests.

Check the runtime logs for:

```text
SunSpec connection ready
```

### The power value differs from the SMA web interface

Compare the following values:

```text
Enapter: Real-time Active Power
SMA: Real-time Active Power
```

Do not compare the sum of only two estimated phase values with the total inverter power.

Also ensure that both interfaces are being viewed at approximately the same time. The SMA web interface and Enapter may refresh their values at different intervals.

## Upload checklist

1. Set `DEVICE_HOST` in `main.lua` to the reachable SMA IP address.
2. Keep TCP port `502` unless the SMA configuration uses another port.
3. Keep Unit ID `1` unless the installation uses a different Unit ID.
4. Place `manifest.yml` and `main.lua` in the same Blueprint directory.
5. Assign the Blueprint to the Virtual UCM on the Enapter Gateway.
6. Upload the Blueprint.
7. Search the logs for `SunSpec connection ready`.
8. Confirm that telemetry arrives with the actual inverter status.
9. Compare SMA `Real-time Active Power` with Enapter `Real-time Active Power`.

## Safety and scope

This Blueprint is read-only.

It does not:

- Write Modbus registers.
- Change inverter settings.
- Change active power limits.
- Control the inverter.
- Store or transmit the SMA web interface password.

The Blueprint only reads SunSpec Modbus TCP measurements and sends them to Enapter.

## References

[1] Enapter Developer Toolkit, Modbus TCP API:  
https://developers.enapter.com/docs/reference/vucm/modbustcp

[2] Enapter Handbook, Universal Communication Modules, ENP-VIRTUAL:  
https://dev-handbook.enapter.com/modules/modules.html

[3] Enapter Handbook, Virtual UCM:  
https://handbook.enapter.com/software/virtual_ucm/

[4] SunSpec Models Repository, Model 103, Inverter Three Phase:  
https://raw.githubusercontent.com/sunspec/models/master/json/model_103.json

[5] SMA, Sunny Tripower CORE2 technical information:  
https://files.sma.de/downloads/STP60_SHP75_STPS60-SunSpec_Modbus-TI-en-15.pdf

[6] SMA, Sunny Tripower CORE2 product and Modbus SunSpec information:  
https://www.sma.de/en/products/solarinverters/sunny-tripower-core2
