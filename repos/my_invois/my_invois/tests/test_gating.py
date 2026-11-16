"""The demo contract: no credentials means no outbound call and no fake submit."""

from unittest.mock import patch

import frappe
from frappe.tests.utils import FrappeTestCase

from my_invois.my_invois.api import (
    build_invoice_document,
    get_myinvois_settings,
    submit_to_myinvois,
    validate_for_myinvois,
)


class TestMyInvoisGating(FrappeTestCase):
    def setUp(self):
        self.docname = frappe.db.get_value("Sales Invoice", {"docstatus": 1}, "name")
        if not self.docname:
            self.skipTest("no submitted Sales Invoice in this site - seed the demo data first")

    def test_settings_contract(self):
        settings = get_myinvois_settings()
        for key in ("configured", "api_base_url", "token_endpoint", "environment"):
            self.assertIn(key, settings)
        self.assertIsInstance(settings["configured"], bool)

    def test_validate_returns_errors_and_ready(self):
        result = validate_for_myinvois(self.docname)
        self.assertIn("errors", result)
        self.assertIn("ready", result)
        self.assertEqual(result["ready"], not result["errors"])
        self.assertIsInstance(result["errors"], list)

    def test_document_builder_outputs_a_dict(self):
        document = build_invoice_document(self.docname)
        self.assertIsInstance(document, dict)
        self.assertTrue(document)

    def test_unconfigured_submit_never_calls_lhdn(self):
        # Simulate a fresh clone: no client credentials in site_config.
        with patch.dict(frappe.conf, {"myinvois_client_id": None, "myinvois_client_secret": None}):
            if not validate_for_myinvois(self.docname)["ready"]:
                self.skipTest("seeded invoice does not satisfy MyInvois validation")

            with patch("my_invois.my_invois.api._get_access_token") as token:
                token.side_effect = AssertionError("LHDN must not be contacted without credentials")
                result = submit_to_myinvois(self.docname)

            token.assert_not_called()
            self.assertEqual(result["status"], "Pending Validation")
            self.assertIn("NOT", result["message"])
            self.assertIn("not configured", result["message"].lower())
            self.assertEqual(
                frappe.db.get_value("Sales Invoice", self.docname, "myinvois_status"),
                "Pending Validation",
            )
