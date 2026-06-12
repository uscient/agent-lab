---
description: NEW revision of an existing tmp/ doc (never overwrite)
---
Create a NEW revision — do not edit the prior doc.

Args: $ARGUMENTS   (first token = base doc name, rest = the change)

Use `tools/new-revision.sh <base> <short-suffix>`, carry forward still-valid content, mark what changed and what it supersedes in the front-matter, and leave prior revisions untouched.
