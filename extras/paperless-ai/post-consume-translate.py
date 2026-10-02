#!/usr/bin/env python3
"""Post-consume hook: write a concise English summary into Paperless custom
fields via Ollama, auto-title the document, and -- for documents the model
itself identifies as a genuine receipt/invoice -- extract the EUR total and
push a transaction into Actual Budget. Runs inside the paperless_webserver
container after every consume. Summarizing rather than translating
line-by-line lets the model drop OCR noise and boilerplate instead of being
locked into preserving every garbled line.

Whether a document is a receipt is decided by the model reading its content,
not by Paperless's own "Receipt" document type (that's an ML classifier
trained on past tagging habits -- not reliable enough to gate a real money
entry on, since a false positive would silently invent an expense).

Never fails consumption: any error here is logged and swallowed, since this
whole pipeline is an enhancement, not core functionality.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

PAPERLESS_URL = "http://localhost:8000"
API_TOKEN = os.environ["PAPERLESS_API_TOKEN"]
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434")
# 7b, not 3b: 3b was unreliable on this task specifically (tested against a
# real garbled Bulgarian receipt -- often transliterated instead of
# translating, or produced nothing useful, even at temperature 0). 7b gave
# consistently correct, readable translations. Slower (~100s/doc on 4GB
# VRAM, partial CPU offload) but this runs async per-document, not
# interactively, so latency doesn't matter here.
MODEL = os.environ.get("TRANSLATE_MODEL", "qwen2.5:7b")
MAX_CHARS = 6000  # ~1500 tokens/chunk

ACTUAL_API_URL = os.environ.get("ACTUAL_HTTP_API_URL", "")
ACTUAL_API_KEY = os.environ.get("ACTUAL_HTTP_API_KEY", "")
ACTUAL_SYNC_ID = os.environ.get("ACTUAL_BUDGET_SYNC_ID", "")
ACTUAL_ACCOUNT_NAME = os.environ.get("ACTUAL_ACCOUNT_NAME", "Receipts")
# PAPERLESS_ACTUAL_POST=no in homelab.env: receipts still get Amount (and no
# Expense), so they can be posted later, but nothing reaches Actual.
ACTUAL_POST = os.environ.get("ACTUAL_POST_RECEIPTS", "yes").lower() not in ("no", "false", "0")

CYRILLIC_RE = re.compile(r"[Ѐ-ӿ]")
SPANISH_RE = re.compile(r"[ñÑ]|\b(factura|total|fecha|gracias|impuesto)\b", re.IGNORECASE)
DATE_RE = re.compile(r"^(\d{1,2})/(\d{1,2})/(\d{4})$")


def detect_language(text):
    """Naming the source language explicitly and confidently in the prompt
    made a large, repeatable difference in translation quality during
    testing -- an ambiguous "could be A, B, or C" framing performed far
    worse than a single confident claim, even when wrong language detection
    would presumably confuse things more. Cheap heuristic, not ML."""
    if CYRILLIC_RE.search(text):
        return "Bulgarian"
    if SPANISH_RE.search(text):
        return "Spanish"
    return "English"


def api_get(path):
    req = urllib.request.Request(
        f"{PAPERLESS_URL}{path}",
        headers={"Authorization": f"Token {API_TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def api_write(path, body, method="POST"):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{PAPERLESS_URL}{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Token {API_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def api_post(path, body):
    return api_write(path, body, method="POST")


def api_patch(path, body):
    return api_write(path, body, method="PATCH")


def ollama_chat(prompt):
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
    }
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/chat",
        data=data,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=180) as r:
        resp = json.load(r)
    return resp["message"]["content"].strip()


def ollama_chat_json(prompt):
    # format="json" forces syntactically valid JSON; the prompt still spells
    # out the exact shape we want since that alone doesn't guarantee it.
    # temperature 0: this is factual extraction, not summarization -- we
    # want the same document to parse the same way every run.
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "format": "json",
        "options": {"temperature": 0},
    }
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{OLLAMA_URL}/api/chat",
        data=data,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=180) as r:
        resp = json.load(r)
    return json.loads(resp["message"]["content"])


def chunk_text(text, max_chars=MAX_CHARS):
    return [text[i : i + max_chars] for i in range(0, len(text), max_chars)] or [""]


def summarize_chunk(chunk, lang):
    lang_hint = f"This document is in {lang}. " if lang != "English" else ""
    prompt = (
        f"{lang_hint}It was OCR-scanned and may contain recognition errors. "
        "In 2-3 sentences, describe: what kind of document this is (for a "
        "receipt: what business/place it's from and roughly what kind of "
        "purchase this was -- a brief category, not an itemized list of "
        "every item), the date written as DD/MM/YYYY, and the total amount "
        "in EUROS (ignore any "
        "Bulgarian Lev or other older currency shown, even if printed "
        "larger or first -- no longer used, only kept on receipts for "
        "reference). Write entirely in English -- do not include Bulgarian "
        "words or Cyrillic characters, except for proper names with no "
        "English equivalent. Output only the summary:\n\n" + chunk
    )
    return ollama_chat(prompt)


def summarize(text):
    lang = detect_language(text)
    chunks = chunk_text(text)
    if len(chunks) == 1:
        return summarize_chunk(chunks[0], lang)
    # Long document: summarize each piece, then combine into one summary --
    # avoids either truncating content or exceeding context in a single call.
    partials = [summarize_chunk(c, lang) for c in chunks]
    combine_prompt = (
        "These are summaries of consecutive parts of the same document. "
        "Combine them into one cohesive summary, removing repetition:\n\n"
        + "\n\n".join(partials)
    )
    return ollama_chat(combine_prompt)


def generate_title(summary):
    # Derived from the summary, not the raw OCR text: cheaper (short input)
    # and the summary already isolates the details that make a title
    # meaningful (place, purchase type, date) from OCR noise.
    prompt = (
        "Based on this document summary, write a short, descriptive title "
        "suitable for filing (5-8 words). No quotes, no trailing "
        "punctuation, no date in the title. Output only the title, one "
        "line:\n\n" + summary
    )
    title = ollama_chat(prompt).strip()
    # Strip wrapping quotes/newlines a model sometimes adds despite instructions.
    return title.splitlines()[0].strip().strip("\"'").strip()


def extract_receipt_details(text, category_names):
    """Single combined classification + extraction call: is this actually a
    receipt/invoice (not a letter, ID, contract, etc -- deciding this from
    content, not from Paperless's own unreliable ML-guessed document type),
    and if so, its payee/date/EUR total/category. Returns a dict; at minimum
    {"is_receipt": False} on any failure, so callers can always check that
    key without extra error handling."""
    lang = detect_language(text)
    lang_hint = f"This document is in {lang}. " if lang != "English" else ""
    category_list = ", ".join(sorted(category_names)) if category_names else "none available"
    prompt = (
        f"{lang_hint}This document was OCR-scanned and may contain "
        "recognition errors. Determine whether it is a genuine receipt, "
        "invoice, or proof of payment for a purchase -- NOT a letter, ID "
        "document, contract, medical record, or any other document that "
        "isn't a completed transaction.\n\n"
        "Reply with ONLY a JSON object, no other text, exactly in this "
        "shape:\n"
        '{"is_receipt": true or false, "payee": "business or place name, '
        'or null", "date": "DD/MM/YYYY or null", "amount_eur": number or '
        'null, "category": "one of the categories below, or null"}\n\n'
        "Rules:\n"
        "- is_receipt: true only if this is an actual purchase/payment "
        "document. If unsure, use false.\n"
        "- payee: written in Latin script (transliterated if the original "
        "is in Cyrillic or another script), the way you would write it in "
        "an English sentence -- not copied verbatim in the original "
        "script.\n"
        "- amount_eur: the FINAL TOTAL paid, in EUROS. If a Bulgarian Lev "
        "or other older currency is also shown, use the EUR figure, not "
        "the other one -- older currencies are kept on receipts for "
        "reference only, no longer in use. null if is_receipt is false or "
        "no EUR amount is shown.\n"
        f"- category: pick the single best match from: {category_list}. "
        "Use exactly one of those names, or null if none fit well or "
        "is_receipt is false.\n\n"
        "Document text:\n" + text[:MAX_CHARS]
    )
    try:
        result = ollama_chat_json(prompt)
    except (json.JSONDecodeError, KeyError, urllib.error.URLError, TimeoutError):
        return {"is_receipt": False}
    if not isinstance(result, dict) or not isinstance(result.get("is_receipt"), bool):
        return {"is_receipt": False}
    return result


def to_iso_date(date_str):
    if not date_str:
        return None
    m = DATE_RE.match(date_str.strip())
    if not m:
        return None
    day, month, year = m.groups()
    try:
        return f"{int(year):04d}-{int(month):02d}-{int(day):02d}"
    except ValueError:
        return None


def get_field_id(name):
    fields = api_get("/api/custom_fields/?page_size=100")
    for f in fields["results"]:
        if f["name"] == name:
            return f["id"]
    return None


def actual_configured():
    return bool(ACTUAL_API_URL and ACTUAL_API_KEY and ACTUAL_SYNC_ID)


def actual_request(path, body=None, method="GET"):
    url = f"{ACTUAL_API_URL}/v1/budgets/{ACTUAL_SYNC_ID}{path}"
    headers = {"x-api-key": ACTUAL_API_KEY}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def get_or_create_actual_account(name):
    accounts = actual_request("/accounts")["data"]
    for a in accounts:
        if a["name"] == name:
            return a["id"]
    created = actual_request(
        "/accounts", {"account": {"name": name, "offbudget": False, "initialBalance": 0}}, method="POST"
    )
    return created["data"]


def get_actual_expense_categories():
    cats = actual_request("/categories")["data"]
    return {c["name"]: c["id"] for c in cats if not c.get("hidden") and not c.get("is_income")}


def push_actual_transaction(doc_id, doc_created, details, account_id, category_id):
    iso_date = to_iso_date(details.get("date")) or (doc_created or "")[:10]
    txn = {
        "account": account_id,
        "date": iso_date,
        "amount": -round(details["amount_eur"] * 100),  # cents, negative = outflow
        "payee_name": details.get("payee") or "Unknown",
        "notes": f"Paperless doc #{doc_id}",
        # Dedupes on re-runs (e.g. manual testing) -- Actual's import
        # reconciliation matches on this instead of creating a duplicate.
        "imported_id": f"paperless-{doc_id}",
    }
    if category_id:
        txn["category"] = category_id
    actual_request(
        f"/accounts/{account_id}/transactions/import",
        {"transactions": [txn], "defaultCleared": True, "dryRun": False, "reimportDeleted": False},
        method="POST",
    )


def main():
    doc_id = int(os.environ["DOCUMENT_ID"])

    doc = api_get(f"/api/documents/{doc_id}/")
    content = doc.get("content", "")
    if not content.strip():
        return

    field_updates = {}

    summary = summarize(content)
    summarised_id = get_field_id("Summarised")
    summary_id = get_field_id("Summary")
    if summarised_id:
        field_updates[str(summarised_id)] = True
    if summary_id:
        field_updates[str(summary_id)] = summary

    # Auto-generated titles instead of leaving files as DOC_<timestamp>,
    # which is meaningless outside of the date. Direct write, no approval
    # step -- unlike Paperless's native AI suggestions, which only suggest.
    title = generate_title(summary)
    if title:
        api_patch(f"/api/documents/{doc_id}/", {"title": title})

    categories = {}
    if actual_configured():
        try:
            categories = get_actual_expense_categories()
        except Exception as e:
            print(f"post-consume-translate.py: could not fetch Actual categories: {e}", file=sys.stderr)

    details = extract_receipt_details(content, categories.keys())

    if details.get("is_receipt") and details.get("amount_eur"):
        amount_id = get_field_id("Amount")
        if amount_id:
            field_updates[str(amount_id)] = details["amount_eur"]

        if actual_configured() and ACTUAL_POST:
            try:
                account_id = get_or_create_actual_account(ACTUAL_ACCOUNT_NAME)
                category_id = categories.get(details.get("category"))
                push_actual_transaction(doc_id, doc.get("created"), details, account_id, category_id)
                expense_id = get_field_id("Expense")
                if expense_id:
                    field_updates[str(expense_id)] = True
            except Exception as e:
                print(f"post-consume-translate.py: Actual push failed: {e}", file=sys.stderr)

    if field_updates:
        api_post(
            "/api/documents/bulk_edit/",
            {
                "documents": [doc_id],
                "method": "modify_custom_fields",
                "parameters": {
                    "add_custom_fields": field_updates,
                    "remove_custom_fields": [],
                },
            },
        )


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 -- never fail consumption over this
        print(f"post-consume-translate.py error: {e}", file=sys.stderr)
        sys.exit(0)
