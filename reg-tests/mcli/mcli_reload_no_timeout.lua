-- Delay worker readiness by 2s to test that serverfin does not
-- kill the reload command while the new worker is starting.
core.register_init(function()
    os.execute("sleep 2")
end)
