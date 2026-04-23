-- Copyright (c) 2025 dyphire <qimoge@gmail.com>
-- Modified: Add polling + frame-back-step for 8K HDR smooth switching
-- License: MIT

local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    hdr_mode = "noth",
    fullscreen_only = false,
    target_peak = "203",
    target_contrast = "auto",
}
options.read_options(o)

local hdr_active = false
local first_switch_check = true
local file_loaded = false

local saved = {
    icc_profile = mp.get_property_native("icc-profile"),
    icc_profile_auto = mp.get_property_native("icc-profile-auto"),
    target_peak = mp.get_property_native("target-peak"),
    target_prim = mp.get_property_native("target-prim"),
    target_trc = mp.get_property_native("target-trc"),
    target_contrast = mp.get_property_native("target-contrast"),
    colorspace_hint = mp.get_property_native("target-colorspace-hint"),
    inverse_mapping = mp.get_property_native("inverse-tone-mapping"),
}

local function query_hdr_state()
    hdr_active = mp.get_property_native("user-data/display-info/hdr-status") == "on"
end

local function switch_display_mode(enable)
    if enable == hdr_active then return end
    mp.commandv('script-message', 'toggle-hdr-display', enable and "on" or "off")
end

local function apply_hdr_settings()
    mp.set_property_native("icc-profile", "")
    mp.set_property_native("icc-profile-auto", false)
    mp.set_property_native("target-prim", "bt.2020")
    mp.set_property_native("target-trc", "pq")
    mp.set_property_native("target-peak", o.target_peak)
    mp.set_property_native("target-contrast", o.target_contrast)
    mp.set_property_native("target-colorspace-hint", "yes")
    mp.set_property_native("inverse-tone-mapping", "no")
end

local function apply_sdr_settings()
    mp.set_property_native("icc-profile", saved.icc_profile)
    mp.set_property_native("icc-profile-auto", saved.icc_profile_auto)
    mp.set_property_native("target-peak", "203")
    mp.set_property_native("target-contrast", saved.target_contrast)
    mp.set_property_native("target-colorspace-hint", "no")
    mp.set_property_native("target-prim", saved.target_prim == "bt.2020" and "auto" or saved.target_prim)
    mp.set_property_native("target-trc", saved.target_trc == "pq" and "auto" or saved.target_trc)
end

local function reset_target_settings()
    mp.set_property_native("target-peak", saved.target_peak)
    mp.set_property_native("target-prim", saved.target_prim)
    mp.set_property_native("target-trc", saved.target_trc)
    mp.set_property_native("target-contrast", saved.target_contrast)
    mp.set_property_native("target-colorspace-hint", saved.colorspace_hint)
    mp.set_property_native("inverse-tone-mapping", saved.inverse_mapping)
end

local function pause_if_needed()
    local paused = mp.get_property_native("pause")
    if not paused then
        mp.set_property_native("pause", true)
        return true
    end
    return false
end

local function resume_if_needed(paused_before)
    if paused_before then
        mp.add_timeout(1, function()
            mp.set_property_native("pause", false)
        end)
    end
end

-- 轮询等待 HDR 状态稳定
local function wait_for_hdr_state(target_state, callback, timeout_sec)
    timeout_sec = timeout_sec or 5.0
    local start = mp.get_time()
    local last = nil
    local stable_cnt = 0

    local function poll()
        query_hdr_state()
        local current = hdr_active
        if current == target_state then
            if last == current then
                stable_cnt = stable_cnt + 1
            else
                stable_cnt = 0
            end
            last = current
            if stable_cnt >= 2 then  -- 连续两次相同，认为稳定
                callback()
                return
            end
        else
            stable_cnt = 0
            last = nil
        end
        if mp.get_time() - start > timeout_sec then
            msg.warn("Timeout waiting for HDR state to become " .. tostring(target_state))
            callback()
            return
        end
        mp.add_timeout(0.1, poll)
    end
    poll()
end

local function handle_hdr_logic(paused_before, target_peak, target_prim, target_trc)
    query_hdr_state()
    if hdr_active and o.hdr_mode ~= "noth" then
        apply_hdr_settings()
        resume_if_needed(paused_before)
    elseif not hdr_active and o.hdr_mode ~= "noth" and
           (tonumber(target_peak) ~= 203 or target_prim == "bt.2020" or target_trc == "pq") then
        apply_sdr_settings()
    end
end

local function handle_sdr_logic(paused_before, target_peak, target_prim, target_trc)
    query_hdr_state()
    if not hdr_active or o.hdr_mode ~= "noth" then
        if (not hdr_active or not saved.inverse_mapping) and
           (tonumber(target_peak) ~= 203 or target_prim == "bt.2020" or target_trc == "pq") then
            apply_sdr_settings()
        elseif hdr_active and saved.inverse_mapping then
            reset_target_settings()
        end
        resume_if_needed(paused_before)
    end
    if hdr_active and o.hdr_mode == "pass" and saved.inverse_mapping then
        reset_target_settings()
    end
end

local function should_switch_hdr(is_fullscreen)
    if o.hdr_mode ~= "switch" then return false end
    if not hdr_active and (not o.fullscreen_only or is_fullscreen) then
        return true
    elseif hdr_active and o.fullscreen_only and not is_fullscreen then
        return true
    end
    return false
end

-- 切换后的处理：使用 frame-back-step（作者推荐的方式）
local function after_hdr_switch(pause_changed, continue_func)
    -- frame-back-step: 回退一帧，清空损坏帧缓冲区，重置同步状态
    mp.commandv("frame-back-step")
    msg.info("HDR switch completed, frame-back-step executed")
    
    if not pause_changed then
        mp.set_property_native("pause", false)
    end
    continue_func()
end

local function on_video_params_change()
    local params = mp.get_property_native("video-params")
    if not params then return end
    local max_luma = params["max-luma"] or 0
    local is_hdr = max_luma > 203

    local fullscreen = mp.get_property_native("fullscreen") or false
    local maximized = mp.get_property_native("window-maximized") or false
    local is_fullscreen = fullscreen or maximized
    local target_peak = mp.get_property_native("target-peak")
    local target_prim = mp.get_property_native("target-prim")
    local target_trc = mp.get_property_native("target-trc")
    local pause_changed = false

    if is_hdr then
        local function continue_hdr()
            handle_hdr_logic(pause_changed, target_peak, target_prim, target_trc)
        end

        if first_switch_check and o.fullscreen_only and not is_fullscreen then
            first_switch_check = false
        elseif should_switch_hdr(is_fullscreen) then
            pause_changed = pause_if_needed()
            local target_hdr = not (hdr_active and o.fullscreen_only and not is_fullscreen)
            if target_hdr then
                msg.info("Switching to HDR output...")
                switch_display_mode(true)
                wait_for_hdr_state(true, function()
                    after_hdr_switch(pause_changed, continue_hdr)
                end)
            else
                msg.info("Switching to SDR output...")
                switch_display_mode(false)
                wait_for_hdr_state(false, function()
                    after_hdr_switch(pause_changed, continue_hdr)
                end)
            end
            return
        end
        handle_hdr_logic(false, target_peak, target_prim, target_trc)
    else
        local function continue_sdr()
            handle_sdr_logic(pause_changed, target_peak, target_prim, target_trc)
        end

        if hdr_active and o.hdr_mode == "switch" and (not o.fullscreen_only or is_fullscreen) then
            msg.info("Switching back to SDR output...")
            pause_changed = pause_if_needed()
            switch_display_mode(false)
            wait_for_hdr_state(false, function()
                after_hdr_switch(pause_changed, continue_sdr)
            end)
            return
        end
        handle_sdr_logic(false, target_peak, target_prim, target_trc)
    end
end

local function enforce_hdr_settings()
    query_hdr_state()
    local params = mp.get_property_native("video-params")
    if not params then return end
    local max_luma = params["max-luma"] or 0
    local is_hdr = max_luma > 203

    local target_peak = mp.get_property_native("target-peak")
    local target_prim = mp.get_property_native("target-prim")
    local target_trc = mp.get_property_native("target-trc")
    local target_contrast = mp.get_property_native("target-contrast")
    local colorspace_hint = mp.get_property_native("target-colorspace-hint")
    local inverse_mapping = mp.get_property_native("inverse-tone-mapping")

    if is_hdr and hdr_active and o.hdr_mode ~= "noth" then
        if target_peak ~= o.target_peak then mp.set_property_native("target-peak", o.target_peak) end
        if target_contrast ~= o.target_contrast then mp.set_property_native("target-contrast", o.target_contrast) end
        if target_prim ~= "bt.2020" then mp.set_property_native("target-prim", "bt.2020") end
        if target_trc ~= "pq" then mp.set_property_native("target-trc", "pq") end
        if colorspace_hint ~= "yes" then mp.set_property_native("target-colorspace-hint", "yes") end
        if inverse_mapping then mp.set_property_native("inverse-tone-mapping", "no") end
    end
    if not is_hdr and o.hdr_mode ~= "noth" and not saved.inverse_mapping and
       (tonumber(target_peak) ~= 203 or target_prim == "bt.2020" or target_trc == "pq") then
        apply_sdr_settings()
    end
end

local function on_start()
    if o.hdr_mode == "noth" or tonumber(o.target_peak) <= 203 then
        return
    end
    local vo = mp.get_property("vo")
    if vo ~= "gpu-next" then
        msg.warn("hdr-mode.lua requires vo=gpu-next, current vo=" .. tostring(vo))
        return
    end
    file_loaded = true
    query_hdr_state()
    mp.observe_property("video-params", "native", on_video_params_change)
    mp.observe_property("target-peak", "native", enforce_hdr_settings)
    mp.observe_property("target-prim", "native", enforce_hdr_settings)
    mp.observe_property("target-trc", "native", enforce_hdr_settings)
    mp.observe_property("target-contrast", "native", enforce_hdr_settings)
    mp.observe_property("target-colorspace-hint", "native", enforce_hdr_settings)
    mp.observe_property("user-data/display-info/hdr-status", "native", on_video_params_change)
    if o.fullscreen_only then
        mp.observe_property("fullscreen", "native", on_video_params_change)
        mp.observe_property("window-maximized", "native", on_video_params_change)
    end
end

local function on_end(event)
    query_hdr_state()
    first_switch_check = true
    mp.unobserve_property(on_video_params_change)
    mp.unobserve_property(enforce_hdr_settings)
    if event.reason == "quit" and o.hdr_mode == "switch" and hdr_active then
        msg.info("Restoring display to SDR on shutdown")
        switch_display_mode(false)
    end
end

local function on_idle(_, active)
    if not active then return end
    local target_peak = mp.get_property_native("target-peak")
    local target_prim = mp.get_property_native("target-prim")
    local target_trc = mp.get_property_native("target-trc")
    if o.hdr_mode ~= "noth" and
       (tonumber(target_peak) ~= 203 or target_prim == "bt.2020" or target_trc == "pq") then
        apply_sdr_settings()
    end
    if file_loaded and o.hdr_mode == "switch" then
        file_loaded = false
        query_hdr_state()
        if hdr_active then
            msg.info("Restoring display to SDR on idle")
            switch_display_mode(false)
        end
    end
end

mp.register_event("start-file", on_start)
mp.register_event("end-file", on_end)
mp.observe_property("idle-active", "native", on_idle)
