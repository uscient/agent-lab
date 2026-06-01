# .devguard

Plaintext guard configuration for `scripts/dev/guard-diff`.

Files:

- `forbid-default.txt`: always checked.
- `forbid-<scope>.txt`: checked when running `scripts/dev/guard-diff <scope>`.

Example:

```bash
./scripts/dev/guard-diff M2
```

Then `.devguard/forbid-M2.txt` is applied in addition to defaults.
