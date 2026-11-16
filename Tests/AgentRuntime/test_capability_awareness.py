"""Local prompt upgrade and permission-failure regressions; never uses a live profile."""
from copy import deepcopy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Apps/MacApp/Runtime"))
from superagent_runtime import MOMO_COMPUTER_CAPABILITY, MOMO_PROMPT_CONFIG, _upgrade_prompt_defaults
from superagent_computer import SuperAgentComputer


class CapabilityPromptTests(unittest.TestCase):
    def test_stock_shared_prompt_upgrades_without_replacing_custom_skills_or_policy(self):
        previous = deepcopy(MOMO_PROMPT_CONFIG)
        previous["overrides"]["runtime/shared"]["text"] = "Worker has Mac desktop control."
        previous["skills"]["momo"] = "Old built-in skill."
        current = deepcopy(previous)
        current["scope"] = "User policy stays."
        current["skills"]["browser"] = "User browser skill stays."
        current["overrides"]["runtime/shared"]["base"] = "runtime-maintained-hash"
        upgraded = _upgrade_prompt_defaults(previous, current, MOMO_PROMPT_CONFIG)
        self.assertIn(MOMO_COMPUTER_CAPABILITY, upgraded["overrides"]["runtime/shared"]["text"])
        self.assertIn(MOMO_COMPUTER_CAPABILITY, upgraded["skills"]["momo"])
        self.assertEqual(upgraded["skills"]["browser"], current["skills"]["browser"])
        self.assertEqual(upgraded["scope"], current["scope"])

    def test_custom_shared_prompt_and_removed_skill_are_not_overwritten(self):
        previous = deepcopy(MOMO_PROMPT_CONFIG)
        previous["overrides"]["runtime/shared"]["text"] = "Previous stock text."
        current = deepcopy(previous)
        current["overrides"]["runtime/shared"]["text"] = "Owner customization."
        del current["skills"]["momo"]
        upgraded = _upgrade_prompt_defaults(previous, current, MOMO_PROMPT_CONFIG)
        self.assertEqual(upgraded["overrides"]["runtime/shared"]["text"], "Owner customization.")
        self.assertNotIn("momo", upgraded["skills"])


class CapabilityReadinessTests(unittest.IsolatedAsyncioTestCase):
    async def test_registered_bridge_preserves_permission_or_missing_backend_error_without_retry(self):
        for failure in ("请先在 Mac 的「屏幕与控制权限」中开启辅助功能。", "内置电脑组件不可用，请重新构建或更新应用。"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                ticket = {"state": "open", "assignments": [{"id": "run-1", "state": "running"}]}
                bridge = SuperAgentComputer(Path(tmp), AsyncMock(return_value=ticket))
                with patch("superagent_computer.native_request", AsyncMock(return_value={"error": failure})) as native:
                    with self.assertRaises(RuntimeError) as caught:
                        await bridge.call("ticket-1", "run-1", "accessibility-snapshot", {})
                    self.assertEqual(str(caught.exception), failure)
                    native.assert_awaited_once()
                self.assertEqual(bridge.observations, {})
        self.assertIn("不能建议重复安装来代替授权", MOMO_COMPUTER_CAPABILITY)


if __name__ == "__main__":
    unittest.main()
