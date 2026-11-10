--[[
    # Usage
    KEY script-message toggle_autocrop
--]]

local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"

local autocrop_opts = {
    osd = "Autocrop",
    label = "autocrop",
    cropdetect_limit = "24/255",
    cropdetect_round = 16,
    min_crop_width = 0.5,
    min_crop_height = 0.5,
    symmetry_ratio = 0.75,
    crop_tolerance = 0.01,
}
options.read_options(autocrop_opts)

local CROPDETECT_LABEL = "@" .. autocrop_opts.label
local UPLOAD_LABEL = "@" .. autocrop_opts.label .. "_upload"
local CROPDETECT_FILTER = "%s:%s=limit=%s:reset=1:round=%d" -- reset=1 detects each frame on its own
local UPLOAD_FILTER = "%s:format=fmt=vulkan" -- uploads software frames to Vulkan
local DEBOUNCE_SECONDS = 0.3 -- time a detected crop must stay unchanged before it is applied
local MAX_DETECTION_SPEED = 2.0 -- playback speed above which detection is skipped

local autocrop_state = {
    active = false,
    properties = { speed = 1, seeking = false, pause = false },
    metadata = nil,
    applied = nil,
    pending = nil,
    debounce_timer = nil,
}

local function set_active(active)
    autocrop_state.active = active
    mp.set_property_native("user-data/filter/" .. autocrop_opts.label, active)
end

set_active(false)

local function is_vulkan_context()
    local gpu_context = mp.get_property("current-gpu-context")
    return gpu_context ~= nil and gpu_context:sub(-#"vk") == "vk"
end

-- Returns the filter for the frames of the current decoder, and whether they
-- have to be uploaded to Vulkan first, or nil for other hardware decoders.
local function get_detection_filter()
    local hwdec = mp.get_property("hwdec-current", "no")
    if hwdec == "vulkan" then
        return "cropdetect_vulkan", false
    elseif hwdec == "nvdec" then
        return "cropdetect_cuda", false
    elseif hwdec == "no" or hwdec:sub(-#"-copy") == "-copy" then
        return "cropdetect_vulkan", true
    end
    return nil
end

local function has_filter(label)
    for _, filter in ipairs(mp.get_property_native("vf") or {}) do
        if "@" .. (filter.label or "") == label then
            return true
        end
    end
    return false
end

-- Returns whether the filters are in the chain.
local function insert_autocrop(filter_name, needs_upload)
    if has_filter(CROPDETECT_LABEL) then
        return true
    end

    if needs_upload and not mp.commandv("vf", "append", string.format(UPLOAD_FILTER, UPLOAD_LABEL)) then
        return false
    end
    if not mp.commandv("vf", "append", string.format(CROPDETECT_FILTER, CROPDETECT_LABEL,
            filter_name, autocrop_opts.cropdetect_limit, autocrop_opts.cropdetect_round)) then
        if needs_upload then
            mp.commandv("vf", "remove", UPLOAD_LABEL)
        end
        return false
    end
    return true
end

local function clamp_crop(crop_size, crop_pos, min_size, max_size)
    if max_size - crop_size <= max_size * autocrop_opts.crop_tolerance then
        return max_size, 0
    end

    crop_size = math.max(crop_size, min_size)
    crop_pos = math.min(crop_pos, max_size - crop_size)

    local margin_start = crop_pos
    local margin_end = max_size - crop_size - crop_pos
    if math.min(margin_start, margin_end) < math.max(margin_start, margin_end) * autocrop_opts.symmetry_ratio then
        return max_size, 0
    end
    return crop_size, crop_pos
end

local function is_same_crop(crop, other)
    local tolerance_w = crop.max_w * autocrop_opts.crop_tolerance
    local tolerance_h = crop.max_h * autocrop_opts.crop_tolerance
    return math.abs(crop.w - other.w) <= tolerance_w and math.abs(crop.x - other.x) <= tolerance_w
        and math.abs(crop.h - other.h) <= tolerance_h and math.abs(crop.y - other.y) <= tolerance_h
end

local function apply_crop(crop)
    if crop.w == crop.max_w and crop.h == crop.max_h then
        mp.set_property("file-local-options/video-crop", "")
    else
        mp.set_property("file-local-options/video-crop", string.format("%dx%d+%d+%d", crop.w, crop.h, crop.x, crop.y))
    end
end

local function apply_pending_crop()
    autocrop_state.applied = autocrop_state.pending
    autocrop_state.pending = nil
    apply_crop(autocrop_state.applied)
end

local function cancel_pending_crop()
    autocrop_state.pending = nil
    if autocrop_state.debounce_timer then
        autocrop_state.debounce_timer:kill()
    end
end

-- Applies a detected crop once it has not changed for DEBOUNCE_SECONDS.
local function debounce_crop(crop)
    local state = autocrop_state
    if state.applied and is_same_crop(crop, state.applied) then
        cancel_pending_crop()
    elseif not state.pending or not is_same_crop(crop, state.pending) then
        state.pending = crop
        state.debounce_timer:kill()
        if not state.properties.pause then
            state.debounce_timer:resume()
        end
    end
end

local function get_detected_crop(cropdetect_metadata)
    local max_w = mp.get_property_native("video-out-params/w")
    local max_h = mp.get_property_native("video-out-params/h")
    if not max_w or not max_h then return nil end

    local w = tonumber(cropdetect_metadata["lavfi.cropdetect.w"])
    local h = tonumber(cropdetect_metadata["lavfi.cropdetect.h"])
    local x = tonumber(cropdetect_metadata["lavfi.cropdetect.x"])
    local y = tonumber(cropdetect_metadata["lavfi.cropdetect.y"])
    if not (w and h and x and y) then return nil end
    -- A black frame has no picture to crop to, so it leaves the crop as it is.
    if w <= 0 or h <= 0 then return nil end

    local crop = { max_w = max_w, max_h = max_h }
    crop.w, crop.x = clamp_crop(w, x, max_w * autocrop_opts.min_crop_width, max_w)
    crop.h, crop.y = clamp_crop(h, y, max_h * autocrop_opts.min_crop_height, max_h)
    return crop
end

local function update_autocrop()
    local state = autocrop_state
    if not state.metadata or state.properties.seeking or state.properties.speed > MAX_DETECTION_SPEED then
        return
    end

    local crop = get_detected_crop(state.metadata)
    if crop then
        debounce_crop(crop)
    else
        cancel_pending_crop()
    end
end

local function handle_metadata(_, cropdetect_metadata)
    autocrop_state.metadata = cropdetect_metadata
    update_autocrop()
end

local function handle_speed(_, value)
    autocrop_state.properties.speed = value
    if value > MAX_DETECTION_SPEED then
        cancel_pending_crop()
    else
        update_autocrop()
    end
end

local function handle_seeking(_, value)
    autocrop_state.properties.seeking = value
    if value then
        cancel_pending_crop()
    else
        update_autocrop()
    end
end

local function handle_pause(_, value)
    autocrop_state.properties.pause = value
    if value then
        autocrop_state.debounce_timer:kill()
    elseif autocrop_state.pending then
        autocrop_state.debounce_timer:resume()
    end
end

local function observe_properties()
    mp.observe_property("speed", "number", handle_speed)
    mp.observe_property("seeking", "bool", handle_seeking)
    mp.observe_property("pause", "bool", handle_pause)
    mp.observe_property("vf-metadata/" .. autocrop_opts.label, "native", handle_metadata)
end

local function unobserve_properties()
    mp.unobserve_property(handle_metadata)
    mp.unobserve_property(handle_speed)
    mp.unobserve_property(handle_seeking)
    mp.unobserve_property(handle_pause)
    autocrop_state.properties = { speed = 1, seeking = false, pause = false }
end

local function start_autocrop(filter_name, needs_upload)
    if not insert_autocrop(filter_name, needs_upload) then
        return false
    end
    autocrop_state.debounce_timer = mp.add_timeout(DEBOUNCE_SECONDS, apply_pending_crop, true)
    observe_properties()
    return true
end

local function cleanup_autocrop()
    unobserve_properties()
    cancel_pending_crop()
    autocrop_state.debounce_timer = nil
    autocrop_state.metadata = nil
    autocrop_state.applied = nil

    if has_filter(CROPDETECT_LABEL) then
        mp.commandv("vf", "remove", CROPDETECT_LABEL)
    end
    if has_filter(UPLOAD_LABEL) then
        mp.commandv("vf", "remove", UPLOAD_LABEL)
    end
    mp.set_property("file-local-options/video-crop", "")
end

local function enable_autocrop()
    if mp.get_property_native("current-tracks/video/image") then
        msg.warn("Not available for image files")
        return false
    end

    if not is_vulkan_context() then
        msg.warn("Requires gpu-context=winvk, waylandvk or x11vk")
        return false
    end

    local filter_name, needs_upload = get_detection_filter()
    if not filter_name then
        msg.warn("Not available for hwdec=" .. mp.get_property("hwdec-current", "no"))
        return false
    end

    if not start_autocrop(filter_name, needs_upload) then
        msg.warn("Could not insert " .. filter_name)
        return false
    end
    set_active(true)
    return true
end

local function disable_autocrop()
    cleanup_autocrop()
    set_active(false)
end

-- Returns whether the state has changed to the requested one.
local function set_autocrop(enable)
    if enable == autocrop_state.active then
        return false
    end

    if enable then
        return enable_autocrop()
    end
    disable_autocrop()
    return true
end

local function handle_toggle(operation)
    local enable = operation == "enable" or (operation == nil and not autocrop_state.active)
    if not set_autocrop(enable) then
        return
    end

    if enable then
        mp.osd_message(autocrop_opts.osd .. ": yes")
    else
        mp.osd_message(autocrop_opts.osd .. ": no")
    end
end

mp.add_hook("on_unload", 50, function() set_autocrop(false) end)
mp.register_script_message("toggle_autocrop", handle_toggle)
mp.register_script_message("enable_autocrop", function() set_autocrop(true) end)
mp.register_script_message("disable_autocrop", function() set_autocrop(false) end)
