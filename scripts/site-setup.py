#!/usr/bin/env python3
"""Idempotent post-install configuration for the Frappe CRM site.

Run inside the backend container, with the site's env vars present:

    docker exec -e MAIL_PW=... -e JOSH_PW=... -e ADMIN_API_KEY=... \
        -e ADMIN_API_SECRET=... -i <backend> \
        bash -c 'bench --site <site> console < /tmp/site-setup.py'

`bench console` already has `frappe` connected to the site. Everything here is
safe to re-run: the user and Email Account are looked up before creation, and
the flags are overwritten with the intended values.
"""

import os

import frappe

SITE = os.environ.get("SITE_NAME", "frappe.forefrontinvestors.com")
MAIL_EMAIL = os.environ.get("MAIL_EMAIL", "josh@forefrontinvestors.com")
MAIL_PW = os.environ["MAIL_PW"]
JOSH_PW = os.environ["JOSH_PW"]

# --- site settings ----------------------------------------------------------
frappe.db.set_single_value("System Settings", "enable_scheduler", 1)
frappe.db.set_single_value("System Settings", "time_zone", "America/New_York")
frappe.db.set_single_value("System Settings", "language", "en")
frappe.db.commit()

# --- the mailbox owner's login ---------------------------------------------
if frappe.db.exists("User", MAIL_EMAIL):
    user = frappe.get_doc("User", MAIL_EMAIL)
else:
    user = frappe.get_doc(
        {
            "doctype": "User",
            "email": MAIL_EMAIL,
            "first_name": "Josh",
            "last_name": "Klein",
            "user_type": "System User",
            "send_welcome_email": 0,
            "roles": [{"role": "System Manager"}, {"role": "Sales Manager"}],
        }
    ).insert(ignore_permissions=True)
user.new_password = JOSH_PW
user.save(ignore_permissions=True)

# --- two-way mailbox --------------------------------------------------------
account_name = "Josh - Forefront Investors"
if frappe.db.exists("Email Account", account_name):
    acc = frappe.get_doc("Email Account", account_name)
else:
    acc = frappe.get_doc({"doctype": "Email Account", "email_account_name": account_name})

acc.update(
    {
        "email_id": MAIL_EMAIL,
        "password": MAIL_PW,
        "enable_incoming": 1,
        "use_imap": 1,
        "email_server": "imap.purelymail.com",
        "use_ssl": 1,
        "incoming_port": "993",
        "default_incoming": 1,
        "email_sync_option": "ALL",
        "initial_sync_count": "250",
        "imap_folder": [{"folder_name": "INBOX"}],
        "enable_outgoing": 1,
        "default_outgoing": 1,
        "smtp_server": "smtp.purelymail.com",
        "smtp_port": "587",
        "use_tls": 1,
        "no_smtp_authentication": 0,
        "track_email_status": 1,
        "send_unsubscribe_message": 0,
        "create_lead_from_incoming_email": 1,
        "always_use_account_email_id_as_sender": 1,
        "append_emails_to_sent_folder": 0,
    }
)
if acc.is_new():
    acc.insert(ignore_permissions=True)
else:
    acc.save(ignore_permissions=True)

# --- API key for automation ------------------------------------------------
admin = frappe.get_doc("User", "Administrator")
admin.api_key = os.environ.get("ADMIN_API_KEY", admin.api_key or "frappe-crm-automation")
admin.api_secret = os.environ.get("ADMIN_API_SECRET", "change-me")
admin.save(ignore_permissions=True)
frappe.db.commit()
