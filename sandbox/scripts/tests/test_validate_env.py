import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


VALIDATOR = Path(__file__).resolve().parents[1] / "validate-env.py"
DEFAULT_PASSWORDS = {
    "DB_ROOT_PASSWORD": "admin",
    "ERPNEXT_ADMIN_PASSWORD": "admin",
    "METABASE_DB_PASS": "metabase_demo_2026",
    "METABASE_ADMIN_PASSWORD": "DemoPass2026!",
}


class ValidateEnvironmentTests(unittest.TestCase):
    def run_validator(self, environment, passwords, process_env=None):
        contents = [f"ENVIRONMENT={environment}"]
        contents.extend(f"{key}={value}" for key, value in passwords.items())
        with tempfile.TemporaryDirectory() as temp_dir:
            env_file = Path(temp_dir) / ".env"
            env_file.write_text("\n".join(contents) + "\n", encoding="utf-8")
            child_env = os.environ.copy()
            for key in (*DEFAULT_PASSWORDS, "ENVIRONMENT"):
                child_env.pop(key, None)
            child_env.update(process_env or {})
            return subprocess.run(
                [sys.executable, str(VALIDATOR), "--env-file", str(env_file)],
                check=False,
                capture_output=True,
                text=True,
                env=child_env,
            )

    def test_development_reports_but_allows_demo_passwords(self):
        result = self.run_validator("development", DEFAULT_PASSWORDS)
        self.assertEqual(result.returncode, 0)
        self.assertIn("DB_ROOT_PASSWORD", result.stdout)
        self.assertIn("METABASE_ADMIN_PASSWORD", result.stdout)

    def test_production_rejects_demo_passwords_and_lists_keys(self):
        result = self.run_validator("production", DEFAULT_PASSWORDS)
        self.assertEqual(result.returncode, 1)
        for key in DEFAULT_PASSWORDS:
            self.assertIn(key, result.stderr)

    def test_production_allows_replaced_passwords(self):
        replaced = {key: f"custom-{index}-secret" for index, key in enumerate(DEFAULT_PASSWORDS)}
        result = self.run_validator("production", replaced)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("none", result.stdout)

    def test_production_rejects_placeholder_password(self):
        passwords = dict(DEFAULT_PASSWORDS)
        passwords["METABASE_DB_PASS"] = "__FILL_ME__"
        result = self.run_validator("production", passwords)
        self.assertEqual(result.returncode, 1)
        self.assertIn("METABASE_DB_PASS", result.stderr)

    def test_production_checks_process_environment_overrides(self):
        passwords = {key: f"custom-{index}-secret" for index, key in enumerate(DEFAULT_PASSWORDS)}
        result = self.run_validator(
            "production",
            passwords,
            {"METABASE_DB_PASS": "metabase_demo_2026"},
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("METABASE_DB_PASS", result.stderr)

    def test_production_rejects_default_password_with_inline_comment(self):
        passwords = {key: f"custom-{index}-secret" for index, key in enumerate(DEFAULT_PASSWORDS)}
        passwords["DB_ROOT_PASSWORD"] = '"admin" # demo default'
        result = self.run_validator("production", passwords)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DB_ROOT_PASSWORD", result.stderr)


if __name__ == "__main__":
    unittest.main()
