# -*- coding: utf-8 -*-
from __future__ import unicode_literals

app_name = "my_invois"
app_title = "Malaysia E-Invoicing (MyInvois)"
app_publisher = "erpnextcomp_demo"
app_description = "Integration-ready Malaysia LHDN MyInvois e-invoicing layer (preparation, validation, status lifecycle, gated submission)."
app_icon = "octicon octicon-file"
app_color = "grey"
app_email = "support@example.com"
app_license = "MIT"

# Custom Fields (TIN/BRN/SST + e-invoice status/references) and the Sales
# Invoice Client Script are installed on `bench migrate` via fixtures.
fixtures = ["Custom Field", "Client Script"]

# The Sales Invoice "MyInvois" actions are driven by the Client Script fixture.
# No automatic submission on the ERPNext submit hook: submission to LHDN is
# always explicit and gated on credentials, never a side effect of saving.
