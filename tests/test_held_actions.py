"""Run with: python -m pip install lupa; python -m unittest discover -s tests.

Execute the production Lua functions with mocked cross-resource exports/catalogue.
No game, database or resource startup is needed.
"""
from pathlib import Path
import unittest

from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


def function_source(path, start, end):
    source = (ROOT / path).read_text(encoding="utf-8-sig")
    return source[source.index(start):source.index(end, source.index(start))]


class HeldActions(unittest.TestCase):
    def inventory(self, export_result):
        lua = LuaRuntime(unpack_returned_tuples=True)
        calls, messages = [], []
        lua.globals().callExport = lambda *args: (calls.append(args) or export_result)
        lua.globals().tell = lambda *args: messages.append(args)
        apply = lua.execute(function_source(
            "rp_inventory/server/main.lua", "local function applyEffect(",
            "-- Uses one unit of an item:") + "\nreturn applyEffect")
        definition = lua.table_from({"label": "Cigarettes", "effect": lua.table_from({"kind": "smoke"})})
        return apply, definition, calls, messages

    def test_smoking_calls_needs_once(self):
        apply, definition, calls, messages = self.inventory((True, True, None))
        self.assertTrue(apply(7, "cigarettes", definition))
        self.assertEqual(calls, [("rp_needs", "consume", 7, "cigarettes")])
        self.assertIn("smoke", messages[0][1])

    def test_refused_consumption_does_not_report_success(self):
        apply, definition, calls, messages = self.inventory((True, None, "player_not_found"))
        self.assertEqual(apply(7, "cigarettes", definition), (None, "player_not_found"))
        self.assertEqual(messages, [])

    def test_needs_offline_preserves_flavour_fallback(self):
        apply, definition, calls, messages = self.inventory((False, None, None))
        self.assertTrue(apply(7, "cigarettes", definition))
        self.assertIn("No needs system", messages[0][1])

    def test_resource_defined_item_keeps_its_own_effect(self):
        apply, definition, calls, messages = self.inventory((True, True, None))
        definition.definedBy = "custom_job"
        self.assertTrue(apply(7, "custom_cigarette", definition))
        self.assertEqual(calls, [])

    def test_bar_catalogue_fallbacks_and_disable(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("Open77 = {animations = {}}; function log() end")
        known, played = set(), []
        lua.globals().Open77.animations.get = lambda name: lua.table() if name in known else None
        lua.globals().Open77.animations.play = lambda *args: (played.append(args) or lua.table())
        play = lua.execute(function_source(
            "rp_bar/server/main.lua", "local function playProfile(",
            "local function applyWobble(") + "\nreturn playProfile")
        candidates = lua.table_from(["bottle_walk", "bottle", "drink"])
        for available, expected in [({"bottle_walk", "drink"}, "bottle_walk"),
                                    ({"drink"}, "drink"), (set(), None)]:
            known.clear()
            known.update(available)
            played.clear()
            play(7, candidates, 4000)
            self.assertEqual([call[1] for call in played], [expected] if expected else [])
        play(7, False, 4000)
        self.assertEqual(played, [])
        play(7, "custom_drink", 4000)
        self.assertEqual(played[0][1], "custom_drink")
        self.assertEqual(played[0][2].durationMs, 4000)
        self.assertFalse(played[0][2].loop)


if __name__ == "__main__":
    unittest.main()
