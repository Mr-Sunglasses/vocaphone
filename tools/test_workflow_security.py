"""Regression checks for the boundary between PR compilation and signing."""

import json
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent


class WorkflowSecurityTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load((ROOT / ".github/workflows/pr-build.yml").read_text())

    def test_contributor_builds_have_no_secrets_or_write_token(self):
        for name in ("android-build", "ios-build"):
            with self.subTest(job=name):
                job = self.workflow["jobs"][name]
                self.assertNotIn("secrets.", json.dumps(job))
                self.assertNotIn("write", job["permissions"].values())
                self.assertNotIn("environment", job)
                checkout = next(step for step in job["steps"] if step.get("uses", "").startswith("actions/checkout@"))
                self.assertEqual(checkout["with"]["ref"], "${{ needs.prepare.outputs.sha }}")
                self.assertFalse(checkout["with"]["persist-credentials"])

    def test_signers_do_not_build_contributor_code(self):
        for name in ("android", "ios"):
            with self.subTest(job=name):
                job = self.workflow["jobs"][name]
                self.assertIn("pr-signing", job["environment"]["name"])
                steps = json.dumps(job["steps"])
                self.assertNotIn("./gradlew", steps)
                self.assertNotIn("xcodegen", steps)
                self.assertNotIn("-project VocaPhone", steps)
                self.assertIn("EXPECTED_SHA", steps)
                self.assertIn(".head.sha", steps)
                for step in job["steps"]:
                    if step.get("uses", "").startswith("actions/checkout@"):
                        self.assertEqual(step["with"]["ref"], "${{ github.workflow_sha }}")
                    if name == "android" and "secrets." in json.dumps(step):
                        self.assertEqual(step["if"], "needs.prepare.outputs.quick != 'true'")

    def test_external_actions_are_immutable(self):
        for path in (ROOT / ".github").rglob("*.yml"):
            def walk(value):
                if isinstance(value, dict):
                    if isinstance(value.get("uses"), str) and not value["uses"].startswith("./"):
                        self.assertRegex(value["uses"], r"@[0-9a-f]{40}$", str(path))
                    for child in value.values():
                        walk(child)
                elif isinstance(value, list):
                    for child in value:
                        walk(child)
            walk(yaml.safe_load(path.read_text()))

    def test_gate_policy_is_pinned_independently(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/ci.yml').read_text())
        scope = workflow['jobs']['scope']['steps']
        gate = workflow['jobs']['gate']['steps']
        policy = next(step for step in scope if step.get('with', {}).get('path') == '.ci-policy')
        self.assertRegex(policy['with']['ref'], r'^[0-9a-f]{40}$')
        self.assertEqual(policy['with']['repository'], 'VocaHQ/vocaphone')
        self.assertEqual(gate[0]['with']['ref'], policy['with']['ref'])
        self.assertEqual(scope[-1]['run'], 'python3 .ci-policy/tools/ci_scope.py select')


if __name__ == "__main__":
    unittest.main()
