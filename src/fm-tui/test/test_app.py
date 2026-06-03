"""fm_tui app tests: it mounts and composes its panels headless, bare of nish-tui."""

import asyncio

from fm_tui.app import FmTuiApp


def test_app_mounts_all_panels():
    async def go():
        async with FmTuiApp().run_test() as pilot:
            await pilot.pause()
            app = pilot.app
            assert app.query_one("#nodes") is not None
            assert app.query_one("#topics") is not None
            assert app.query_one("#rosout") is not None

    asyncio.run(go())


def test_app_uses_fallback_widgets_when_nish_tui_absent():
    # Step 6 wires the plain twins directly, so the app never imports nish-tui.
    import fm_tui.app as app_module

    assert app_module.Header.__module__ == "fm_tui.widgets"
    assert app_module.LogView.__module__ == "fm_tui.widgets"
