# Paperless AI

A Paperless post-consume script that runs on every imported document:

- writes a concise **English summary** to a `Summary` custom field (and
  sets `Summarised`), whatever the document's language;
- replaces auto-generated titles (`DOC_<timestamp>`, scanner file names)
  with a meaningful one;
- asks the model whether the document is a **real receipt or invoice**
  (its own yes/no, not Paperless's ML "Receipt" type, which is a guess) and
  if so sets `Amount`/`Expense` and creates a transaction in **Actual
  Budget**'s "Receipts" account, deduplicated on re-import.

Plus Paperless's own AI suggestions (title, correspondent, tags, type) via
the same local Ollama.

> Personal tuning: amounts are read as **EUR** (older Bulgarian lev
> figures are ignored), prompts mention Bulgarian receipts, dates are
> DD/MM/YYYY. Edit `post-consume-translate.py` for your currency.

Enable: stacks `paperless-ngx`, `ollama`, `actual-budget`, and
`PAPERLESS_AI=yes` (the wizard asks). Then, once:

1. `docker exec ollama ollama pull qwen2.5:3b && docker exec ollama ollama pull qwen2.5:7b`
2. In Paperless, create custom fields: `Summary` (Long text), `Summarised`
   (Boolean), `Amount` (Monetary), `Expense` (Boolean). The script matches
   them by name.
3. Paperless > My Profile > API token: `./lab config paperless-ngx PAPERLESS_API_TOKEN`
4. Actual: set its password on first visit, then
   `./lab config actual-budget ACTUAL_SERVER_PASSWORD` and
   `./lab config actual-budget ACTUAL_BUDGET_SYNC_ID` (Settings > Show
   advanced settings > Sync ID).
5. `./lab up paperless-ngx actual-budget`

Errors are logged and swallowed: the script never makes an import fail.
Known limit: payee names for small local businesses can come out
inconsistently transliterated (a 7B model limit); amounts and dates are
reliable.
