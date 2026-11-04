# -*- coding: utf-8 -*-
"""Malaysia LHDN MyInvois e-invoicing — submit-only layer.

Architecture (matches the business rule):
    * ERPNext **Sales Invoice** is the single source of truth for every
      calculation (prices, taxes, discounts, totals). Nothing here computes
      money.
    * This module only **validates**, **maps** the invoice to the UBL 2.1
      Invoice structure LHDN accepts (document type "Invoice v1.0"), **wraps**
      it into the MyInvois submission envelope (base64 + SHA256), **submits**
      it, and **records the response** (submissionUID, document UUID,
      accepted/rejected, validation link / long ID for the QR).

Submission is NEVER faked: without client credentials the invoice is validated
and marked "Pending Validation" and the caller is told nothing was sent to LHDN.

References (authoritative):
    https://sdk.myinvois.hasil.gov.my/einvoicingapi/02-submit-documents/
    https://sdk.myinvois.hasil.gov.my/documents/invoice-v1-0/
"""
from __future__ import unicode_literals

import base64
import hashlib
import json

import frappe
from frappe import _
from frappe.utils import cstr, flt, now_datetime, nowdate

MYINVOIS_STATUS = [
    "Draft", "Pending Validation", "Validated", "Submitted",
    "Accepted", "Rejected", "Cancelled",
]

# LHDN e-Invoice type codes (https://sdk.myinvois.hasil.gov.my/codes/e-invoice-types/)
EINVOICE_TYPE_CODES = {
    "Invoice": "01",
    "Credit Note": "02",
    "Debit Note": "03",
    "Refund Note": "04",
}

# LHDN tax type codes (https://sdk.myinvois.hasil.gov.my/codes/tax-types/)
# 01 = Sales Tax, 02 = Service Tax, 03 = Tourism Tax, 04 = High-Value Goods Tax, 05 = Low-Value Goods Tax, 06 = Any tax not listed above
TAX_TYPE_CODES = {
    "sales": "01", "sales tax": "01",
    "service": "02", "service tax": "02",
    "tourism": "03", "tourism tax": "03",
    "lvg": "05", "low value goods": "05",
}

# UN/ECE Rec 20 unit codes for common ERPNext UOMs.
UOM_CODES = {
    "nos": "C62", "unit": "C62", "pc": "C62", "pcs": "C62", "pieces": "C62",
    "kg": "KGM", "kgs": "KGM", "g": "GRM", "gram": "GRM",
    "m": "MTR", "meter": "MTR", "metre": "MTR",
    "l": "LTR", "liter": "LTR", "litre": "LTR",
    "hour": "HUR", "hr": "HUR", "day": "DAY",
}

# UBL namespace prefixes MyInvois expects at the document root.
UBL_NS = {
    "_D": "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
    "_A": "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2",
    "_B": "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2",
}


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

def get_myinvois_settings():
    """Read MyInvois config from site_config.json (frappe.conf).

    `configured` is False when client credentials are absent. Sandbox and
    production endpoints are kept separate.
    """
    conf = frappe.conf
    env = (conf.get("myinvois_environment") or "Sandbox").title()
    base = conf.get("myinvois_api_base_url") or (
        "https://preprod-api.myinvois.hasil.gov.my" if env == "Sandbox"
        else "https://api.myinvois.hasil.gov.my"
    )
    base = base.rstrip("/")
    return {
        "environment": env,
        "api_base_url": base,
        "token_endpoint": conf.get("myinvois_token_endpoint")
            or (base + "/connect/token"),
        "client_id": conf.get("myinvois_client_id"),
        "client_secret": conf.get("myinvois_client_secret"),
        "configured": bool(conf.get("myinvois_client_id") and conf.get("myinvois_client_secret")),
    }


def _get_access_token(settings):
    """Fetch a client-credentials access token from MyInvois (scope InvoicingAPI)."""
    from frappe.integrations.utils import make_post_request
    resp = make_post_request(
        settings["token_endpoint"],
        data={
            "grant_type": "client_credentials",
            "client_id": settings["client_id"],
            "client_secret": settings["client_secret"],
            "scope": "InvoicingAPI",
        },
    )
    token = (resp or {}).get("access_token")
    if not token:
        frappe.throw(_("MyInvois token endpoint returned no access_token."))
    return token


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

@frappe.whitelist()
def validate_for_myinvois(doc_name):
    """Validate a Sales Invoice for MyInvois. Returns {errors: [...], ready: bool}."""
    doc = frappe.get_doc("Sales Invoice", doc_name)
    errors = []

    company = frappe.get_doc("Company", doc.company)
    if not (company.get("myinvois_tin") or company.get("myinvois_brn")):
        errors.append(_("Company {0} has no MyInvois TIN/BRN.").format(doc.company))
    if not company.get("myinvois_msic_code"):
        errors.append(_("Company {0} has no MyInvois MSIC code.").format(doc.company))

    if doc.customer:
        customer = frappe.get_doc("Customer", doc.customer)
        if not (customer.get("myinvois_tin") or customer.get("myinvois_brn")):
            errors.append(_("Customer {0} has no MyInvois TIN/BRN.").format(doc.customer))
    elif doc.get("myinvois_classification") != "B2C":
        errors.append(_("Invoice has no customer but is not classified B2C."))

    if not doc.get("myinvois_classification"):
        errors.append(_("MyInvois classification is not set on this invoice."))
    if not doc.items:
        errors.append(_("Invoice has no line items."))
    if doc.currency != "MYR":
        errors.append(_("MyInvois expects MYR; invoice currency is {0}.").format(doc.currency))
    if flt(doc.grand_total) < 0:
        errors.append(_("Grand total must not be negative."))

    return {"errors": errors, "ready": not errors}


# ---------------------------------------------------------------------------
# Document mapping (UBL 2.1 Invoice -> JSON)
# ---------------------------------------------------------------------------

def _v(value):
    """Wrap a scalar as a UBL-JSON ``{"_": value}`` node."""
    return {"_": value}


def _party_address(doctype, name):
    """Resolve the party's primary Address into the UBL PostalAddress shape."""
    addr_name = None
    if doctype == "Customer":
        addr_name = frappe.db.get_value(doctype, name, "customer_primary_address")
    if not addr_name:
        addr_name = frappe.db.get_value(
            "Dynamic Link",
            {"link_doctype": doctype, "link_name": name, "parenttype": "Address"},
            "parent",
        )

    empty = {
        "CityName": [_v("NA")],
        "PostalZone": [_v("NA")],
        "CountrySubentityCode": [_v("17")],
        "AddressLine": [{"Line": [_v("NA")]}],
        "Country": [{"IdentificationCode": [_v("MYS"), "listID": "ISO3166-1", "listAgencyID": "6"]}],
    }
    if not addr_name:
        return empty

    a = frappe.get_doc("Address", addr_name)
    state_code = a.get("state") or "17"  # LHDN state code stored on the Address.state field
    lines = [l for l in (a.get("address_line1"), a.get("address_line2")) if l] or ["NA"]
    return {
        "CityName": [_v(a.get("city") or "NA")],
        "PostalZone": [_v(a.get("pincode") or "NA")],
        "CountrySubentityCode": [_v(cstr(state_code))],
        "AddressLine": [{"Line": [_v(l)]} for l in lines],
        "Country": [{"IdentificationCode": [_v("MYS"), "listID": "ISO3166-1", "listAgencyID": "6"]}],
    }


def _party(party, doctype):
    """Map a Customer / Company doc into the UBL Accounting{Supplier,Customer}Party."""
    tin = party.get("myinvois_tin")
    brn = party.get("myinvois_brn")
    tin_type = party.get("myinvois_tin_type") or "TIN"

    identifications = []
    if tin:
        identifications.append({"ID": [_v(tin), "schemeID": "TIN"]})
    if brn:
        identifications.append({"ID": [_v(brn), "schemeID": tin_type if tin_type != "TIN" else "BRN"]})
    else:
        # LHDN requires at least one registration identifier.
        identifications.append({"ID": [_v("NA"), "schemeID": "BRN"]})
    identifications.append({"ID": [_v(party.get("myinvois_sst_registration_no") or "NA"), "schemeID": "SST"]})
    identifications.append({"ID": [_v("NA"), "schemeID": "TTX"]})

    name = party.get("customer_name") or party.get("company_name") or party.get("supplier_name") or party.name
    party_json = {
        "Party": [{
            "IndustryClassificationCode": [_v(party.get("myinvois_msic_code") or "00000",
                                             name=party.get("myinvois_business_activity") or "NA")],
            "PartyIdentification": identifications,
            "PostalAddress": [_party_address(doctype, party.name)],
            "PartyLegalEntity": [{"RegistrationName": [_v(name)]}],
            "Contact": [{
                "Telephone": [_v(party.get("myinvois_contact_number") or "+60000000000")],
                "ElectronicMail": [_v(party.get("myinvois_email") or "NA")],
            }],
        }]
    }
    return party_json


def _tax_profile(doc):
    """Return (tax_type_code, tax_rate, total_tax) from the invoice's taxes."""
    tax_type_code = "06"
    tax_rate = 0.0
    total_tax = flt(doc.total_taxes_and_charges)
    charges = doc.get("taxes") or []
    for ch in charges:
        if not ch.get("charge_type") or ch.get("charge_type") == "Actual":
            continue
        desc = " ".join([cstr(ch.get("description")), cstr(ch.get("account_head"))]).lower()
        if "service" in desc:
            tax_type_code = "02"
        elif "tourism" in desc:
            tax_type_code = "03"
        elif "sales" in desc or "sst" in desc:
            tax_type_code = "01"
        tax_rate = flt(ch.get("rate")) if flt(ch.get("rate")) is not None else tax_rate
        break
    return tax_type_code, tax_rate, total_tax


@frappe.whitelist()
def build_invoice_document(doc_name):
    """Map a Sales Invoice to the UBL 2.1 Invoice JSON LHDN accepts (v1.0).

    Returns the document dict (before the base64/hash submission envelope).
    """
    doc = frappe.get_doc("Sales Invoice", doc_name)
    company = frappe.get_doc("Company", doc.company)
    customer = frappe.get_doc("Customer", doc.customer) if doc.customer else None

    tax_type_code, tax_rate, total_tax = _tax_profile(doc)
    type_code = EINVOICE_TYPE_CODES.get(doc.get("myinvois_type") or "Invoice", "01")

    net_total = flt(doc.net_total)
    lines = []
    for i, d in enumerate(doc.items, start=1):
        line_total = flt(d.amount)  # qty * rate (ERPNext "Amount" is already before tax)
        # Distribute header tax proportionally across lines.
        line_tax = (line_total / net_total * total_tax) if net_total else 0.0
        lines.append({
            "ID": [_v(cstr(i))],
            "InvoicedQuantity": [_v(flt(d.qty), unitCode=UOM_CODES.get((d.uom or "").lower(), "C62"))],
            "LineExtensionAmount": [_v(line_total, currencyID="MYR")],
            "TaxTotal": [{
                "TaxAmount": [_v(line_tax, currencyID="MYR")],
                "TaxSubtotal": [{
                    "TaxableAmount": [_v(line_total, currencyID="MYR")],
                    "TaxAmount": [_v(line_tax, currencyID="MYR")],
                    "Percent": [_v(tax_rate)],
                    "TaxCategory": [{
                        "ID": [_v(tax_type_code)],
                        "TaxScheme": [{"ID": [_v("OTH", schemeID="UN/ECE 5153", schemeAgencyID="6")]}],
                    }],
                }],
            }],
            "Item": [{
                "CommodityClassification": [{
                    "ItemClassificationCode": [_v("000", listID="CLASS")],
                }],
                "Description": [_v(d.item_name or d.item_code)],
            }],
            "Price": [{"PriceAmount": [_v(flt(d.rate), currencyID="MYR")]}],
            "ItemPriceExtension": [{"Amount": [_v(line_total, currencyID="MYR")]}],
        })

    now = now_datetime()
    document = dict(UBL_NS)
    document["Invoice"] = [{
        "ID": [_v(doc.name)],
        "IssueDate": [_v(cstr(doc.posting_date or nowdate()))],
        "IssueTime": [_v(now.strftime("%H:%M:%SZ"))],
        "InvoiceTypeCode": [_v(type_code, listVersionID="1.0")],
        "DocumentCurrencyCode": [_v("MYR")],
        "TaxCurrencyCode": [_v("MYR")],
        "AccountingSupplierParty": [_party(company, "Company")],
        "TaxTotal": [{
            "TaxAmount": [_v(total_tax, currencyID="MYR")],
            "TaxSubtotal": [{
                "TaxableAmount": [_v(net_total, currencyID="MYR")],
                "TaxAmount": [_v(total_tax, currencyID="MYR")],
                "TaxCategory": [{
                    "ID": [_v(tax_type_code)],
                    "TaxScheme": [{"ID": [_v("OTH", schemeID="UN/ECE 5153", schemeAgencyID="6")]}],
                }],
            }],
        }],
        "LegalMonetaryTotal": [{
            "LineExtensionAmount": [_v(net_total, currencyID="MYR")],
            "TaxExclusiveAmount": [_v(net_total, currencyID="MYR")],
            "TaxInclusiveAmount": [_v(flt(doc.grand_total), currencyID="MYR")],
            "PayableAmount": [_v(flt(doc.grand_total), currencyID="MYR")],
        }],
        "InvoiceLine": lines,
    }]
    if customer:
        document["Invoice"][0]["AccountingCustomerParty"] = [_party(customer, "Customer")]

    # v1.0 has signature validation disabled; no cac:Signature emitted.
    return document


def _submission_envelope(doc):
    """Wrap a document dict into the MyInvois submission envelope.

    Body: { "documents": [ { format, document (base64), documentHash, codeNumber } ] }
    documentHash is the SHA256 hex of the raw JSON string (before base64).
    """
    raw = json.dumps(doc, separators=(",", ":"), ensure_ascii=False)
    return {
        "documents": [{
            "format": "JSON",
            "document": base64.b64encode(raw.encode("utf-8")).decode("utf-8"),
            "documentHash": hashlib.sha256(raw.encode("utf-8")).hexdigest(),
            "codeNumber": doc["Invoice"][0]["ID"][0]["_"],
        }]
    }


# ---------------------------------------------------------------------------
# Submit / status / cancel
# ---------------------------------------------------------------------------

@frappe.whitelist()
def submit_to_myinvois(doc_name):
    """Validate then submit. Returns {status, message, data}. Never fakes success."""
    doc = frappe.get_doc("Sales Invoice", doc_name)

    if doc.get("myinvois_status") in ("Submitted", "Accepted"):
        return {"status": doc.get("myinvois_status"),
                "message": _("Invoice is already {0}.").format(doc.get("myinvois_status"))}

    validation = validate_for_myinvois(doc_name)
    if not validation["ready"]:
        frappe.db.set_value("Sales Invoice", doc_name, "myinvois_status", "Rejected")
        frappe.db.set_value("Sales Invoice", doc_name, "myinvois_rejection_reason",
                            "; ".join(validation["errors"]))
        return {"status": "Rejected",
                "message": _("Validation failed: {0}").format("; ".join(validation["errors"]))}

    settings = get_myinvois_settings()
    if not settings["configured"]:
        frappe.db.set_value("Sales Invoice", doc_name, "myinvois_status", "Pending Validation")
        return {
            "status": "Pending Validation",
            "message": _("MyInvois is not configured (client credentials missing). The invoice "
                         "passed validation and is marked 'Pending Validation', but was NOT "
                         "submitted to LHDN. Set myinvois_client_id / myinvois_client_secret / "
                         "myinvois_environment in site_config.json to enable submission."),
        }

    try:
        document = build_invoice_document(doc_name)
        payload = _submission_envelope(document)
        token = _get_access_token(settings)
        from frappe.integrations.utils import make_post_request
        resp = make_post_request(
            settings["api_base_url"] + "/api/v1.0/documentsubmissions",
            data=json.dumps(payload),
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        )
        submission_uid = (resp or {}).get("submissionUID")
        accepted = ((resp or {}).get("acceptedDocuments") or [{}])[0]
        rejected = ((resp or {}).get("rejectedDocuments") or [{}])[0]
        document_uuid = accepted.get("uuid")

        frappe.db.set_value("Sales Invoice", doc_name, "myinvois_submission_uid", submission_uid)
        frappe.db.set_value("Sales Invoice", doc_name, "myinvois_submitted_on", now_datetime())

        if document_uuid:
            frappe.db.set_value("Sales Invoice", doc_name, "myinvois_document_uuid", document_uuid)
            frappe.db.set_value("Sales Invoice", doc_name, "myinvois_status", "Submitted")
            return {"status": "Submitted",
                    "message": _("Submitted to MyInvois ({0}). Document UUID: {1}").format(
                        settings["environment"], document_uuid)}
        else:
            err = rejected.get("error", {}) if rejected else {}
            reason = (err.get("code") or "") + ": " + (err.get("message") or _("document rejected"))
            frappe.db.set_value("Sales Invoice", doc_name, "myinvois_status", "Rejected")
            frappe.db.set_value("Sales Invoice", doc_name, "myinvois_rejection_reason", reason)
            return {"status": "Rejected", "message": _("LHDN rejected the document: {0}").format(reason)}
    except Exception as e:
        frappe.log_error(title="MyInvois submission failed for " + doc_name, message=cstr(e))
        frappe.db.set_value("Sales Invoice", doc_name, "myinvois_status", "Rejected")
        frappe.db.set_value("Sales Invoice", doc_name, "myinvois_rejection_reason", cstr(e))
        return {"status": "Rejected", "message": _("Submission failed: {0}").format(cstr(e))}


@frappe.whitelist()
def refresh_myinvois_status(doc_name):
    """Get the latest LHDN validation result and record it.

    Calls GET /api/v1.0/documents/{uuid}/details, which returns the final
    validation status plus the public validation link / long ID used for the QR.
    """
    doc = frappe.get_doc("Sales Invoice", doc_name)
    uuid = doc.get("myinvois_document_uuid")
    if not uuid:
        return {"status": doc.get("myinvois_status"),
                "message": _("No MyInvois document UUID recorded yet.")}

    settings = get_myinvois_settings()
    if not settings["configured"]:
        return {"status": doc.get("myinvois_status"),
                "message": _("MyInvois is not configured; cannot refresh status.")}

    try:
        token = _get_access_token(settings)
        from frappe.integrations.utils import make_get_request
        resp = make_get_request(
            settings["api_base_url"] + "/api/v1.0/documents/" + uuid + "/details",
            headers={"Authorization": "Bearer " + token},
        )
        status = (resp or {}).get("status") or ""
        long_id = (resp or {}).get("longId")
        validation_link = (resp or {}).get("validationLink")
        if status:
            mapped = {"Valid": "Accepted", "Invalid": "Rejected", "Submitted": "Submitted"}.get(status, status)
            frappe.db.set_value("Sales Invoice", doc_name, "myinvois_status", mapped)
        if long_id:
            frappe.db.set_value("Sales Invoice", doc_name, "myinvois_long_id", long_id)
        if validation_link:
            frappe.db.set_value("Sales Invoice", doc_name, "myinvois_validation_link", validation_link)
        return {"status": status or doc.get("myinvois_status"),
                "long_id": long_id, "validation_link": validation_link,
                "message": _("Refreshed from LHDN.")}
    except Exception as e:
        return {"status": doc.get("myinvois_status"), "message": _("Refresh failed: {0}").format(cstr(e))}


@frappe.whitelist()
def cancel_myinvois_document(doc_name, reason=None):
    """Cancel a previously submitted document at LHDN.

    Calls PUT /api/v1.0/documents/{uuid}/state with status "cancelled".
    """
    doc = frappe.get_doc("Sales Invoice", doc_name)
    uuid = doc.get("myinvois_document_uuid")
    if not uuid:
        return {"status": doc.get("myinvois_status"),
                "message": _("No MyInvois document UUID recorded yet.")}

    settings = get_myinvois_settings()
    if not settings["configured"]:
        return {"status": doc.get("myinvois_status"),
                "message": _("MyInvois is not configured; cannot cancel.")}

    try:
        token = _get_access_token(settings)
        from frappe.integrations.utils import make_put_request
        make_put_request(
            settings["api_base_url"] + "/api/v1.0/documents/" + uuid + "/state",
            data=frappe.as_json({"status": "cancelled", "reason": reason or _("Cancelled from ERPNext")}),
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        )
        frappe.db.set_value("Sales Invoice", doc_name, "myinvois_status", "Cancelled")
        return {"status": "Cancelled", "message": _("Cancellation submitted to LHDN.")}
    except Exception as e:
        return {"status": doc.get("myinvois_status"), "message": _("Cancel failed: {0}").format(cstr(e))}
