import unittest

from ci_scope import CHECKS, failures, select


class ScopeTests(unittest.TestCase):
    def test_docs_do_not_require_native_builds(self):
        self.assertEqual(
            {key for key, value in select(["README.md", "ios/README.md"]).items() if value},
            {"semgrep"},
        )

    def test_shared_keyboard_requires_both_platforms(self):
        scope = select(["assets/keyboard/emoji.json"])
        self.assertTrue(all(scope[key] for key in ("android", "ios", "assets")))

    def test_scope_changes_exercise_every_check(self):
        self.assertTrue(all(select(["tools/ci_scope.py"]).values()))

    def test_removed_and_added_files_both_count(self):
        scope = select(["android/old.kt", "ios/new.swift"])
        self.assertTrue(scope["android"] and scope["ios"])

    def test_web_source_requires_security_analysis(self):
        scope = select(["web/app.js"])
        self.assertTrue(scope["web"] and scope["codeql"])
        self.assertFalse(scope["ios"])

    def test_failure_cancel_missing_and_unexpected_skip_fail_closed(self):
        wanted = select(["android/app/build.gradle.kts"])
        needs = {"scope": {"result": "success", "outputs": {
            key: str(value).lower() for key, value in wanted.items()
        }}}
        needs.update({key: {"result": "success" if wanted[key] else "skipped"}
                      for key in CHECKS})
        self.assertEqual(failures(needs), [])
        for result in ("failure", "cancelled", "skipped", None):
            with self.subTest(result=result):
                needs["android"]["result"] = result
                self.assertTrue(failures(needs))
        needs["android"]["result"] = "success"
        self.assertTrue(failures(needs, draft=True))
        needs["scope"]["result"] = "failure"
        self.assertTrue(failures(needs))


if __name__ == "__main__":
    unittest.main()
