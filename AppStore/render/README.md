Screenshots: render the real Settings window (`VoiceFn --smoke-test <dir> --marketing -AppleLanguages "(ru)"`
writes `store-settings-*.png`), copy them here as `<lang>-store-settings-*.png`, run `python3 make.py`, then
render each `<lang>-N.html` with headless Chrome at 1440×900 and `--force-device-scale-factor=2`.
