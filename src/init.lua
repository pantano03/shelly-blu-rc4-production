local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local device_management = require "st.zigbee.device_management"

local SCENES_CLUSTER = 0x0005
local ONOFF_CLUSTER = 0x0006
local LEVEL_CLUSTER = 0x0008

local COMPONENT_BY_BUTTON = {
  [1] = "main",
  [2] = "button2",
  [3] = "button3",
  [4] = "button4"
}

local SUPPORTED_VALUES = { "pushed", "double", "pushed_3x", "held" }

local function get_component(device, component_id)
  for _, component in pairs(device.profile.components) do
    if component.id == component_id then
      return component
    end
  end
  return nil
end

local function emit_button(device, button_number, value)
  local component_id = COMPONENT_BY_BUTTON[button_number]
  if component_id == nil then
    device.log.warn("Ignoring unknown button number " .. tostring(button_number))
    return
  end

  local component = get_component(device, component_id)
  if component == nil then
    device.log.error("Missing component " .. component_id)
    return
  end

  local event_constructor = capabilities.button.button[value]
  if event_constructor == nil then
    device.log.error("Unsupported SmartThings button value " .. tostring(value))
    return
  end

  device.log.info(string.format("Button %d: %s", button_number, value))
  device:emit_component_event(component, event_constructor({ state_change = true }))
end

local function initialize_capabilities(device)
  for button_number = 1, 4 do
    local component = get_component(device, COMPONENT_BY_BUTTON[button_number])
    if component ~= nil then
      device:emit_component_event(
        component,
        capabilities.button.supportedButtonValues(SUPPORTED_VALUES)
      )
    end
  end

  -- SmartThings uses this on the main button capability to describe the remote.
  device:emit_event(capabilities.button.numberOfButtons({ value = 4 }))
end

local function send_bindings(driver, device)
  local hub_eui = driver.environment_info.hub_zigbee_eui

  -- Scene commands identify all four buttons by endpoint.
  for endpoint = 1, 4 do
    device:send(device_management.build_bind_request(
      device, SCENES_CLUSTER, hub_eui, endpoint
    ))
  end

  -- On/Off mode uses endpoints 1 and 2 for single-click and hold commands.
  for endpoint = 1, 2 do
    device:send(device_management.build_bind_request(
      device, ONOFF_CLUSTER, hub_eui, endpoint
    ))
    device:send(device_management.build_bind_request(
      device, LEVEL_CLUSTER, hub_eui, endpoint
    ))
  end

  -- Also bind On/Off on endpoints 3 and 4 in case Toggle mode is enabled.
  for endpoint = 3, 4 do
    device:send(device_management.build_bind_request(
      device, ONOFF_CLUSTER, hub_eui, endpoint
    ))
  end

  device.log.info("Binding requests sent; wake the remote if newly installed")
end

local function added_handler(driver, device)
  initialize_capabilities(device)
end

local function init_handler(driver, device)
  initialize_capabilities(device)
end

local function configure_handler(driver, device)
  initialize_capabilities(device)
  send_bindings(driver, device)
end

local function refresh_handler(driver, device, command)
  send_bindings(driver, device)
end

local function endpoint_value(zb_rx)
  return zb_rx.address_header.src_endpoint.value
end

local function onoff_handler(driver, device, zb_rx)
  local endpoint = endpoint_value(zb_rx)
  local command = zb_rx.body.zcl_header.cmd.value
  local button_number = nil

  -- On/Off mode:
  -- EP1 ON/OFF = buttons 1/2; EP2 ON/OFF = buttons 3/4.
  if endpoint == 1 then
    if command == 0x01 then button_number = 1 end
    if command == 0x00 then button_number = 2 end
  elseif endpoint == 2 then
    if command == 0x01 then button_number = 3 end
    if command == 0x00 then button_number = 4 end
  end

  -- Toggle mode: EP1..EP4, command 0x02.
  if command == 0x02 and endpoint >= 1 and endpoint <= 4 then
    button_number = endpoint
  end

  if button_number ~= nil then
    -- A long press sends a Level Step command followed by an On/Off command
    -- when the key is released. While the hold latch is active, that trailing
    -- On/Off frame is a release notification, not a second short press.
    local hold_key = "hold_active_" .. tostring(button_number)
    if device:get_field(hold_key) then
      device.log.info(string.format(
        "Button %d: suppressing release-generated pushed event",
        button_number
      ))
      return
    end

    emit_button(device, button_number, "pushed")
  else
    device.log.warn(string.format(
      "Unhandled On/Off command: endpoint=0x%02X command=0x%02X",
      endpoint, command
    ))
  end
end

local function scene_handler(driver, device, zb_rx)
  local endpoint = endpoint_value(zb_rx)
  if endpoint < 1 or endpoint > 4 then
    return
  end

  local scene_id = nil
  local ok, value = pcall(function()
    return zb_rx.body.zcl_body.scene_id.value
  end)
  if ok then scene_id = value end

  if scene_id == 0x01 then
    emit_button(device, endpoint, "double")
  elseif scene_id == 0x02 then
    emit_button(device, endpoint, "pushed_3x")
  elseif scene_id == 0x0B then
    emit_button(device, endpoint, "held")
  elseif scene_id == 0x0C or scene_id == 0x0D then
    -- SmartThings has no separate standard values for double-long/triple-long.
    emit_button(device, endpoint, "held")
  else
    device.log.warn("Unhandled scene id " .. tostring(scene_id))
  end
end

local function get_step_direction(zb_rx)
  local candidates = {
    function() return zb_rx.body.zcl_body.step_mode.value end,
    function() return zb_rx.body.zcl_body.move_step_mode.value end,
    function() return zb_rx.body.zcl_body.mode.value end
  }

  for _, getter in ipairs(candidates) do
    local ok, value = pcall(getter)
    if ok and value ~= nil then
      return value
    end
  end

  local printable = zb_rx:pretty_print()
  if string.find(printable, "DOWN") then return 1 end
  if string.find(printable, "UP") then return 0 end
  return nil
end

local function level_step_handler(driver, device, zb_rx)
  local endpoint = endpoint_value(zb_rx)
  local direction = get_step_direction(zb_rx)
  local button_number = nil

  if endpoint == 1 then
    if direction == 0 then button_number = 1 end
    if direction == 1 then button_number = 2 end
  elseif endpoint == 2 then
    if direction == 0 then button_number = 3 end
    if direction == 1 then button_number = 4 end
  end

  if button_number == nil then
    device.log.warn("Unable to map Level Step message")
    return
  end

  -- The remote repeats Step while held. Emit only once until the stream pauses.
  local key = "hold_active_" .. tostring(button_number)
  if not device:get_field(key) then
    device:set_field(key, true)
    emit_button(device, button_number, "held")
  end

  local old_timer = device:get_field(key .. "_timer")
  if old_timer ~= nil then
    device.thread:cancel_timer(old_timer)
  end

  local timer = device.thread:call_with_delay(0.8, function()
    device:set_field(key, false)
    device:set_field(key .. "_timer", nil)
  end)
  device:set_field(key .. "_timer", timer)
end

local driver_template = {
  supported_capabilities = {
    capabilities.button,
    capabilities.battery,
    capabilities.refresh
  },
  lifecycle_handlers = {
    added = added_handler,
    init = init_handler,
    doConfigure = configure_handler
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler
    }
  },
  zigbee_handlers = {
    cluster = {
      [SCENES_CLUSTER] = {
        [0x05] = scene_handler
      },
      [ONOFF_CLUSTER] = {
        [0x00] = onoff_handler,
        [0x01] = onoff_handler,
        [0x02] = onoff_handler
      },
      [LEVEL_CLUSTER] = {
        [0x02] = level_step_handler
      }
    }
  },
  health_check = false
}

defaults.register_for_default_handlers(driver_template, {
  capabilities.battery
})

local driver = ZigbeeDriver("shelly-blu-rc4", driver_template)
driver:run()
